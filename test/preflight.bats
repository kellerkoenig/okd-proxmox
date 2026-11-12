#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Preflight checks against a mocked Proxmox API (test/mocks/curl).

setup() {
	load test_helper
	load_libs
	use_mocks
	FIX=${BATS_TEST_TMPDIR}/fixtures
	cp -r "${OKD_PVE_ROOT}/test/fixtures/pve" "${FIX}"
	export MOCK_PVE_FIXTURES=${FIX}
	make_cluster small
	write_proxmox_conf
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	: >"${LOG_FILE}"
	load_cluster
	proxmox_conf_load
}

@test "Proxmox checks pass against a matching environment" {
	run pf_proxmox
	assert_success
	refute_output --partial "[FAIL]"
	assert_output --partial "[PASS] API reachable, token valid (Proxmox VE 9.2.21)"
	assert_output --partial "[PASS] Privileges on /pool/okd-small"
	assert_output --partial "[PASS] Storage local on pve1 allows iso"
	assert_output --partial "[PASS] Bridge vmbr0 exists on pve3"
	assert_output --partial "[PASS] All 6 VMIDs are free"
	assert_output --partial "[PASS] Host pve1 CPU supports x86-64-v3"
}

@test "the token is sent via stdin config, never as a command line argument" {
	run pf_proxmox
	run cat "${MOCK_LOG}"
	refute_output --partial "${TEST_TOKEN_SECRET}"
	run cat "${MOCK_LOG}.curl-config"
	assert_output --partial "PVEAPIToken=${TEST_TOKEN}"
}

@test "missing privileges are named" {
	jq 'del(."/pool/okd-small"."VM.Config.CDROM") | del(."/storage/local"."Datastore.AllocateTemplate")' \
		"${FIX}/permissions.json" >"${FIX}/p.json" && mv "${FIX}/p.json" "${FIX}/permissions.json"
	PF_FAIL=0
	run pf_proxmox
	assert_output --partial "[FAIL] Missing privileges on /pool/okd-small: VM.Config.CDROM"
	assert_output --partial "[FAIL] Missing privileges on /storage/local: Datastore.AllocateTemplate"
}

@test "unreachable API fails with a hint and without leaking the token" {
	export MOCK_PVE_FAIL=1
	run pf_proxmox
	assert_output --partial "[FAIL] Proxmox API https://pve.example.com:8006/ not usable: curl: (7) Failed to connect to pve.example.com port 8006"
	refute_output --partial "${TEST_TOKEN_SECRET}"
}

@test "used VMIDs, foreign MACs, offline nodes and wrong content types fail" {
	export MOCK_PVE_USED_VMIDS="4101 4121"
	jq '.net0 = "virtio=02:00:41:00:10:04,bridge=vmbr0"' "${FIX}/nodes_pve1_qemu_100_config.json" >"${FIX}/c.json" &&
		mv "${FIX}/c.json" "${FIX}/nodes_pve1_qemu_100_config.json"
	jq 'map(if .storage == "local" then .content = "vztmpl,backup" else . end)' "${FIX}/nodes_pve2_storage.json" >"${FIX}/s.json" &&
		mv "${FIX}/s.json" "${FIX}/nodes_pve2_storage.json"
	jq 'map(if .node == "pve3" then .status = "offline" else . end)' "${FIX}/nodes.json" >"${FIX}/n.json" && mv "${FIX}/n.json" "${FIX}/nodes.json"
	run pf_proxmox
	assert_output --partial "[FAIL] VMIDs already in use: 4101 4121"
	assert_output --partial "[FAIL] MAC addresses already used by other VMs: 02:00:41:00:10:04 (VM 100)"
	assert_output --partial "[FAIL] Storage local on pve2 does not allow content type 'iso'"
	assert_output --partial "[FAIL] Node pve3 is offline"
}

@test "VMs that already belong to this cluster count as owned, not as conflicts" {
	export MOCK_PVE_USED_VMIDS="4100"
	jq '. + [{vmid: 4100, name: "small-master-0", node: "pve1", type: "qemu", status: "running", maxcpu: 8, maxmem: 34359738368, pool: "okd-small"}]' \
		"${FIX}/cluster_resources.json" >"${FIX}/r.json" && mv "${FIX}/r.json" "${FIX}/cluster_resources.json"
	run pf_proxmox
	assert_output --partial "[PASS] All 6 VMIDs are free (1 already belong to this cluster)"
}

@test "capacity: table, RAM overcommit is FAIL, CPU overcommit is WARN with ratio" {
	run pf_capacity
	assert_output --regexp 'HOST +THREADS +vCPU RUNNING +vCPU NEW +CPU RATIO'
	assert_output --regexp 'pve1 +32 +8 +16 +0.8:1'
	assert_output --partial "[PASS] RAM fits on every host"
	assert_output --partial "[PASS] No CPU overcommit"
	yq_set '(.node_groups[] | select(.name == "worker") | .memory_gib) = 220 | (.node_groups[] | select(.name == "worker") | .cpu) = 120'
	load_cluster
	run pf_capacity
	assert_output --partial "[FAIL] pve1: RAM overcommitted by"
	assert_output --partial "[WARN] CPU overcommit above 4:1: pve1=4.2:1"
}

@test "CPU types without x86-64-v2 fail, v2 warns" {
	yq_set '.proxmox.cpu_type = "kvm64"'
	load_cluster
	run pf_cpu_model pve1
	assert_output --partial "[FAIL] CPU type kvm64"
	yq_set '.proxmox.cpu_type = "x86-64-v2-AES"'
	load_cluster
	run pf_cpu_model pve1
	assert_output --partial "[WARN] CPU type x86-64-v2-AES"
}

@test "HA: privileges on /, shared storage, CPU type and two-node clusters" {
	yq_set '.proxmox.ha.enabled = true | .proxmox.cpu_type = "host"'
	load_cluster
	PF_FAIL=0
	run pf_proxmox
	assert_output --partial "[FAIL] Missing privileges on / for proxmox.ha: Sys.Audit Sys.Console"
	assert_output --partial "[FAIL] HA: storage local-lvm is local to each node"
	assert_output --partial "[WARN] HA: cpu_type host"
	refute_output --partial "two-node"

	jq '. + {"/": {"Sys.Audit": 1, "Sys.Console": 1}}' "${FIX}/permissions.json" >"${FIX}/p.json" &&
		mv "${FIX}/p.json" "${FIX}/permissions.json"
	jq 'map(if .storage == "local-lvm" then .shared = 1 else . end)' "${FIX}/nodes_pve1_storage.json" >"${FIX}/s.json" &&
		mv "${FIX}/s.json" "${FIX}/nodes_pve1_storage.json"
	yq_set '.proxmox.cpu_type = "x86-64-v3"'
	load_cluster
	run pf_proxmox
	assert_output --partial "[PASS] Privileges on /"
	assert_output --partial "[PASS] HA: storage local-lvm is shared"
	refute_output --partial "HA: cpu_type"

	jq '.[:2]' "${FIX}/nodes.json" >"${FIX}/n.json" && mv "${FIX}/n.json" "${FIX}/nodes.json"
	run pf_ha pve1
	assert_output --partial "[WARN] HA: two-node Proxmox cluster"
}

@test "storage space: thin pools warn, thick storage fails" {
	jq 'map(if .storage == "local-lvm" then .avail = 107374182400 else . end)' "${FIX}/nodes_pve1_storage.json" >"${FIX}/s.json" &&
		mv "${FIX}/s.json" "${FIX}/nodes_pve1_storage.json"
	run pf_storage_space pve1
	assert_output --partial "[WARN] Space on local-lvm on pve1"
	jq 'map(if .storage == "local-lvm" then .type = "lvm" else . end)' "${FIX}/nodes_pve1_storage.json" >"${FIX}/s.json" &&
		mv "${FIX}/s.json" "${FIX}/nodes_pve1_storage.json"
	run pf_storage_space pve1
	assert_output --partial "[FAIL] Space on local-lvm on pve1: need 376.0 GiB"
}

@test "storage space: VMs that already exist (resumed create) need no new space" {
	jq 'map(if .storage == "local-lvm" then .avail = 107374182400 | .type = "lvm" else . end)' "${FIX}/nodes_pve1_storage.json" >"${FIX}/s.json" &&
		mv "${FIX}/s.json" "${FIX}/nodes_pve1_storage.json"
	local vmid
	while IFS= read -r vmid; do
		PF_OWNED_VMIDS[${vmid}]=existing
	done < <(nodes_query '.[] | select(.host == "pve1") | .vmid' | head -n -1)
	run pf_storage_space pve1
	refute_output --partial "need 376.0 GiB"
	assert_output --regexp '\[(PASS|FAIL)\] Space on local-lvm on pve1: need [0-9.]+ GiB'
	while IFS= read -r vmid; do
		PF_OWNED_VMIDS[${vmid}]=existing
	done < <(nodes_query '.[].vmid')
	run pf_storage_space pve1
	assert_output --partial "[INFO] All VMs of this cluster already exist; skipping the storage space check"
	refute_output --partial "Space on"
}

@test "configuration checks: NTP with two sources warns, infra needs two workers" {
	yq_set '.network.ntp_servers = ["192.0.2.123", "192.0.2.124"]'
	load_cluster
	run pf_ntp
	assert_output --partial "[WARN] Only two NTP servers configured"
	assert_output --partial "no majority"
	yq_set '(.node_groups[] | select(.name == "worker") | .count) = 1'
	load_cluster
	run pf_config
	assert_output --partial "[FAIL] Infra role used with only 1 worker node(s)"
}

@test "DNS: api and *.apps must resolve to the VIPs" {
	export MOCK_DNS="api.small.example.com=192.0.2.5 *.apps.small.example.com=192.0.2.99"
	run pf_network
	assert_output --partial "[PASS] DNS: api resolves to 192.0.2.5"
	assert_output --partial "[FAIL] DNS: *.apps"
	assert_output --partial "expected 192.0.2.6"
	assert_output --partial "[PASS] VIPs and node IPs do not answer (free)"
}

@test "addresses that already answer fail" {
	export MOCK_DNS="api.small.example.com=192.0.2.5 *.apps.small.example.com=192.0.2.6"
	export MOCK_PING_UP="192.0.2.5 192.0.2.22"
	run pf_network
	assert_output --partial "[FAIL] Addresses already answer: VIP 192.0.2.5 192.0.2.22"
}

@test "preflight warns about a yq older than the oldest tested version" {
	local real
	real=$(command -v yq)
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/yq" <<YQ
#!/usr/bin/env bash
[[ \$1 == --version ]] && { echo "yq (https://github.com/mikefarah/yq/) version v4.30.8"; exit 0; }
exec "${real}" "\$@"
YQ
	chmod +x "${BATS_TEST_TMPDIR}/bin/yq"
	PATH=${BATS_TEST_TMPDIR}/bin:${PATH} run pf_local
	assert_output --partial "[WARN] yq v4.30.8 is older than ${YQ_MIN_VERSION}"
	run pf_local
	assert_output --regexp "\[PASS\] jq [0-9.]+, yq v4\.[0-9]+"
}
