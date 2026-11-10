#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Node model: VMIDs, MACs, IPs, serials, host spreading, inventory slots.

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
}

node() {
	nodes_query -r --arg n "$1" ".[] | select(.name == \$n) | $2"
}

@test "VMIDs come from vmid_start plus group offset plus index" {
	assert_equal "$(node small-master-0 .vmid)" 4100
	assert_equal "$(node small-master-2 .vmid)" 4102
	assert_equal "$(node small-worker-0 .vmid)" 4120
	yq_set '(.node_groups[] | select(.name == "worker") | .vmid_offset) = 50'
	load_cluster
	assert_equal "$(node small-worker-1 .vmid)" 4151
}

@test "MAC address is the prefix followed by the VMID" {
	assert_equal "$(node small-master-0 .mac)" "02:00:41:00:10:04"
	assert_equal "$(node small-worker-2 .mac)" "02:00:41:00:10:1a"
	yq_set '.proxmox.mac_prefix = "02:AB:00:00"'
	load_cluster
	assert_equal "$(node small-master-0 .mac)" "02:ab:00:00:10:04"
}

@test "a VMID too large for the MAC bytes is rejected" {
	yq_set '.proxmox.mac_prefix = "02:00:00:00" | .proxmox.vmid_start = 70000 | .proxmox.vmid_end = 70100'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "does not fit into the MAC address bytes"
}

@test "MACs are stable across reloads (deterministic)" {
	local first second
	first=$(nodes_query -c '[.[] | [.name, .vmid, .mac, .ip]]')
	load_cluster
	second=$(nodes_query -c '[.[] | [.name, .vmid, .mac, .ip]]')
	assert_equal "${first}" "${second}"
}

@test "IP ranges expand and are assigned by index" {
	assert_equal "$(node small-master-1 .ip)" 192.0.2.12
	assert_equal "$(node small-worker-2 .ip)" 192.0.2.23
	run jq_lib -nc 'include "nodes"; ["198.51.100.254-198.51.101.1"] | expand_ips'
	assert_output '["198.51.100.254","198.51.100.255","198.51.101.0","198.51.101.1"]'
}

@test "disk serials are short, unique and include the VMID" {
	yq_set '(.node_groups[] | select(.name == "worker") | .data_disks) = [100, {"size_gib": 50, "storage": "ceph-vm"}]'
	load_cluster
	assert_equal "$(node small-worker-0 .boot_serial)" okd4120d0
	assert_equal "$(node small-worker-0 '.data_disks[0].serial')" okd4120d1
	assert_equal "$(node small-worker-0 '.data_disks[1].serial')" okd4120d2
	assert_equal "$(node small-worker-0 '.data_disks[1].storage')" ceph-vm
	assert_equal "$(node small-worker-0 '.data_disks[0].storage')" local-lvm
	run nodes_query '[.[].data_disks[].serial, .[].boot_serial] | (length == (unique | length)) and all(length <= 20)'
	assert_output true
}

@test "control-plane VMs are spread round-robin over Proxmox nodes" {
	assert_equal "$(nodes_query -c '[.[] | select(.agent_role == "master") | .host]')" '["pve1","pve2","pve3"]'
	yq_set '.proxmox.spread = false'
	load_cluster
	assert_equal "$(nodes_query -c '[.[].host] | unique')" '["pve1"]'
	yq_set '.proxmox.spread = true | (.node_groups[] | select(.name == "worker") | .proxmox_nodes) = ["pve3"]'
	load_cluster
	assert_equal "$(nodes_query -c '[.[] | select(.group == "worker") | .host] | unique')" '["pve3"]'
}

@test "spread: balanced shifts every node group by its position" {
	yq_set '.proxmox.nodes = ["pve1", "pve2"]'
	load_cluster
	assert_equal "$(nodes_query -c '[.[] | select(.group == "worker") | .host]')" '["pve1","pve2","pve1"]'
	yq_set '.proxmox.spread = "balanced"'
	load_cluster
	assert_equal "$(nodes_query -c '[.[] | select(.group == "master") | .host]')" '["pve1","pve2","pve1"]'
	assert_equal "$(nodes_query -c '[.[] | select(.group == "worker") | .host]')" '["pve2","pve1","pve2"]'
}

@test "inventory slots with gaps keep VMIDs, MACs and IPs of the other nodes" {
	state_init
	state_inventory_set '{"master":[0,1,2],"worker":[0,2]}'
	assert_equal "$(nodes_query -c '[.[] | select(.group == "worker") | .name]')" '["small-worker-0","small-worker-2"]'
	assert_equal "$(node small-worker-2 .vmid)" 4122
	assert_equal "$(node small-worker-2 .ip)" 192.0.2.23
}

@test "state_inventory_matches_config detects changed counts" {
	state_init
	state_inventory_freeze
	state_inventory_matches_config
	yq_set '(.node_groups[] | select(.name == "worker") | .count) = 4'
	load_cluster
	run state_inventory_matches_config
	assert_failure
}

@test "infra pool only for dedicated infra groups" {
	run infra_pool_enabled
	assert_failure
	make_cluster large
	load_cluster
	infra_pool_enabled
	# a dedicated group plus a combined one (migration) => no pool
	yq_set '(.node_groups[] | select(.name == "worker") | .roles) = ["worker", "infra"]'
	load_cluster
	run infra_pool_enabled
	assert_failure
}

@test "taint_infra defaults: dedicated tainted, combined untainted" {
	make_cluster large
	yq_set 'del(.node_groups[1].taint_infra)'
	load_cluster
	assert_equal "$(node large-infra-0 .taint_infra)" true
	assert_equal "$(node large-worker-0 .taint_infra)" false
	make_cluster small
	yq_set 'del(.node_groups[1].taint_infra)'
	load_cluster
	assert_equal "$(node small-worker-0 .taint_infra)" false
}

@test "agent host entries carry MAC, static IP and the root device serial" {
	run bash -c "$(declare -f nodes_json jq_lib state_inventory_get); $(declare -p OKD_PVE_ROOT CONFIG_JSON NODES_JSON CLUSTER_NAME STATE_DIR OKD_PVE_TMP)
		nodes_json | jq_lib -c --slurpfile c '${CONFIG_JSON}' 'include \"nodes\"; \$c[0] as \$c | .[0] | agent_host(\$c)'"
	assert_success
	assert_output --partial '"macAddress":"02:00:41:00:10:04"'
	assert_output --partial '"ip":"192.0.2.11","prefix-length":24'
	assert_output --partial '"rootDeviceHints":{"serialNumber":"okd4100d0"}'
	assert_output --partial '"next-hop-address":"192.0.2.1"'
}

@test "hostname_format: default, FQDN with {domain}, and invalid formats" {
	assert_equal "$(node small-master-0 .vmid)" 4100
	yq_set '.hostname_format = "{group}-{index}.{cluster}.{domain}"'
	load_cluster
	run config_validate
	assert_success
	assert_equal "$(nodes_query -r '.[0].name')" "master-0.small.example.com"
	assert_equal "$(nodes_query -r '.[3].name')" "worker-0.small.example.com"
	# the VMIDs and MACs do not depend on the name
	assert_equal "$(nodes_query -r '.[0].vmid')" 4100
	yq_set '.hostname_format = "{cluster}-{index}"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "hostname_format must contain {group} and {index}"
	yq_set '.hostname_format = "{cluster}_{group}-{index}"'
	load_cluster
	run config_validate
	assert_failure 2
	assert_output --partial "small_master-0: not a valid hostname"
}

@test "csr_common_name reads the CN of a real CSR, not the bytes after it" {
	local req
	req=$(base64 -w0 <"${OKD_PVE_ROOT}/test/fixtures/csr/small-master-0.pem")
	assert_equal "$(csr_common_name "${req}")" system:node:small-master-0
	assert_equal "$(csr_common_name "$(printf 'not a CSR' | base64 -w0)")" ""
}
