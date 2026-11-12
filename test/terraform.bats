#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# OpenTofu root module and variables generated per cluster (lib/terraform.sh).

setup() {
	load test_helper
	load_libs
	use_mocks
	make_cluster small
	write_proxmox_conf
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	proxmox_conf_load
}

@test "root module points to the shipped module and carries no credentials" {
	tf_write_root
	run cat "${TOFU_DIR}/main.tf"
	assert_output --partial "source = \"${OKD_PVE_ROOT}/terraform\""
	assert_output --partial 'source  = "bpg/proxmox"'
	refute_output --partial "${TEST_TOKEN_SECRET}"
	refute_output --partial "api_token"
	# okd-pve uploads the ISOs itself; the provider gets no upload settings
	refute_output --partial "tmp_dir"
	refute_output --partial "upload_timeout"
}

# _iso_stubs [shared]: fake Proxmox ISO calls; PVE_ISOS lists "<host> <name>"
# of the files on the storage, ISO_LOG the calls.
_iso_stubs() {
	export ISO_LOG=${BATS_TEST_TMPDIR}/iso.log PVE_ISOS=${BATS_TEST_TMPDIR}/pve-isos SHARED=${1:-false}
	: >"${ISO_LOG}"
	touch "${PVE_ISOS}"
	tf_iso_storage_shared() { echo "${SHARED}"; }
	pve_iso_size() { grep -q "^$1 $3\$" "${PVE_ISOS}" && wc -c <"${BATS_TEST_TMPDIR}/agent.iso" | tr -d ' '; }
	pve_iso_upload() {
		echo "upload $1 $2 $4 timeout=$5" >>"${ISO_LOG}"
		echo "$1 $4" >>"${PVE_ISOS}"
	}
	pve_iso_delete() {
		echo "delete $1 $2 $3" >>"${ISO_LOG}"
		[[ -z ${FAIL_DELETE:-} ]] || return 1
		sed -i "\|^$1 $3\$|d" "${PVE_ISOS}"
	}
	echo iso >"${BATS_TEST_TMPDIR}/agent.iso"
	state_init
}

@test "tf_isos_upload uploads every ISO once per host, skips one already there" {
	_iso_stubs false
	tf_iso_register agent "${BATS_TEST_TMPDIR}/agent.iso" '["pve1","pve2","pve1"]'
	local name
	name=$(jq -r '.agent.file_name' "${STATE_DIR}/isos.json")
	echo "pve2 ${name}" >>"${PVE_ISOS}"
	run tf_isos_upload
	assert_success
	assert_equal "$(cat "${ISO_LOG}")" "upload pve1 local ${name} timeout=3600"
	assert_output --partial "${name} is already on local (pve2)"
	# nothing left to upload on the next run
	: >"${ISO_LOG}"
	tf_isos_upload >/dev/null
	assert_equal "$(cat "${ISO_LOG}")" ""
}

@test "tf_isos_upload uploads once to shared ISO storage" {
	_iso_stubs true
	tf_iso_register agent "${BATS_TEST_TMPDIR}/agent.iso" '["pve2","pve1"]'
	tf_isos_upload >/dev/null
	run grep -c '^upload pve2 ' "${ISO_LOG}"
	assert_output 1
	run grep -c '^upload' "${ISO_LOG}"
	assert_output 1
}

@test "an unregistered ISO is deleted after the apply, a failed delete is kept for the next run" {
	_iso_stubs false
	tf_iso_register agent "${BATS_TEST_TMPDIR}/agent.iso" '["pve1","pve2"]'
	tf_isos_upload >/dev/null
	tf_iso_unregister agent
	assert_equal "$(cat "${STATE_DIR}/isos.json")" '{}'
	assert_equal "$(jq -r 'keys[]' "${STATE_DIR}/isos-delete.json")" agent
	FAIL_DELETE=1 run tf_isos_cleanup
	assert_output --partial "Could not delete"
	assert_equal "$(jq -r 'keys[]' "${STATE_DIR}/isos-delete.json")" agent
	tf_isos_cleanup >/dev/null
	assert_equal "$(jq -c . "${STATE_DIR}/isos-delete.json")" '{}'
	assert_equal "$(grep -c . "${PVE_ISOS}")" 0
}

@test "tf_isos_cleanup --all deletes the registered ISOs too (destroy)" {
	_iso_stubs false
	tf_iso_register agent "${BATS_TEST_TMPDIR}/agent.iso" '["pve1"]'
	tf_isos_upload >/dev/null
	tf_isos_cleanup --all >/dev/null
	assert_equal "$(grep -c '^delete pve1 local ' "${ISO_LOG}")" 1
	assert_equal "$(cat "${STATE_DIR}/isos.json")" '{}'
}

@test "variables: nodes keyed by name, ISO per node, no secrets" {
	mkdir -p "${TOFU_DIR}"
	state_init
	tf_iso_register agent /path/agent.x86_64.iso '["pve1","pve2","pve3"]'
	tf_node_isos_set '{"small-master-0":"agent"}'
	tf_write_vars
	local f=${TOFU_DIR}/cluster.auto.json
	assert_equal "$(jq -r '.nodes | keys | length' "${f}")" 6
	assert_equal "$(jq -r '.nodes["small-master-0"].vmid' "${f}")" 4100
	assert_equal "$(jq -r '.nodes["small-master-0"].iso' "${f}")" agent
	assert_equal "$(jq -r '.nodes["small-master-1"].iso' "${f}")" ""
	assert_equal "$(jq -r '.nodes["small-worker-0"].mac' "${f}")" 02:00:41:00:10:18
	assert_regex "$(jq -r '.isos.agent.file_name' "${f}")" '^okd-pve-small-agent-[0-9]{12}\.iso$'
	assert_equal "$(jq -r 'has("iso_storage_shared") or has("upload_timeout")' "${f}")" false
	assert_equal "$(jq -r '.pool_id' "${f}")" okd-small
	assert_equal "$(jq -r '.efi_storage' "${f}")" local-lvm
	assert_equal "$(jq -c '.ha' "${f}")" '{"enabled":false,"max_restart":1,"max_relocate":1}'
	assert_equal "$(jq -r '.guest_agent' "${f}")" true
	run grep -c "${TEST_TOKEN_SECRET}" "${f}"
	assert_output 0
}

@test "shared ISO storage is detected" {
	make_cluster large
	write_proxmox_conf
	load_cluster
	assert_equal "$(tf_iso_storage_shared)" true
	mkdir -p "${TOFU_DIR}"
	tf_write_vars
	assert_equal "$(jq -r '.vlan_id' "${TOFU_DIR}/cluster.auto.json")" 120
}

@test "the guest agent can be switched off" {
	yq_set '.proxmox.guest_agent = false'
	load_cluster
	mkdir -p "${TOFU_DIR}"
	tf_write_vars
	assert_equal "$(jq -r '.guest_agent' "${TOFU_DIR}/cluster.auto.json")" false
}

@test "targeted destroy address" {
	run tf_vm_target small-worker-1
	assert_output '-target=module.okd.proxmox_virtual_environment_vm.node["small-worker-1"]'
}

@test "generated root module validates with tofu (needs network, OKD_PVE_TEST_TOFU=1)" {
	[[ ${OKD_PVE_TEST_TOFU:-0} == 1 ]] || skip "set OKD_PVE_TEST_TOFU=1 to run"
	TOFU=$(command -v tofu)
	mkdir -p "${TOFU_DIR}"
	tf_write_root
	tf_write_vars
	run tofu -chdir="${TOFU_DIR}" init -backend=false -input=false
	assert_success
	run tofu -chdir="${TOFU_DIR}" validate
	assert_success
}

@test "changes that would recreate existing VMs are refused" {
	mkdir -p "${TOFU_DIR}"
	tf_write_vars
	echo '{"resources":[{"type":"proxmox_virtual_environment_vm","instances":[{"index_key":"small-worker-0"}]}]}' \
		>"${TOFU_DIR}/terraform.tfstate"
	# a new group inserted before "worker" shifts the worker VMIDs
	yq_set '.node_groups = [.node_groups[0], {"name": "infra", "roles": ["infra"], "count": 0, "cpu": 8, "memory_gib": 64, "disk_gib": 128, "ips": []}, .node_groups[1]]'
	load_cluster
	run tf_write_vars
	assert_failure 2
	assert_output --partial "small-worker-0: VMID 4120->4140"
	assert_output --partial "would recreate existing VMs"
	# appended at the end it is fine
	yq_set '.node_groups = [.node_groups[0], .node_groups[2], .node_groups[1]]'
	load_cluster
	run tf_write_vars
	assert_success
}
