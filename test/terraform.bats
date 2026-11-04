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
	assert_output --partial "tmp_dir = null"
	refute_output --partial "${TEST_TOKEN_SECRET}"
	refute_output --partial "api_token"
}

@test "provider tmp_dir comes from proxmox.tmp_dir" {
	yq_set '.proxmox.tmp_dir = "/var/tmp/okd-upload"'
	load_cluster
	tf_write_root
	run grep 'tmp_dir' "${TOFU_DIR}/main.tf"
	assert_output --partial 'tmp_dir = "/var/tmp/okd-upload"'
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
	assert_equal "$(jq -r '.iso_storage_shared' "${f}")" false
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
	mkdir -p "${TOFU_DIR}"
	tf_write_vars
	assert_equal "$(jq -r '.iso_storage_shared' "${TOFU_DIR}/cluster.auto.json")" true
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
