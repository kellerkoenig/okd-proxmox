#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# node add / node remove from the command line (mocked tools, no cluster).

setup() {
	load test_helper
	use_mocks
	export NO_COLOR=1
	OKD=${OKD_PVE_ROOT}/okd-pve
	make_cluster small
	write_proxmox_conf
	# pretend the cluster is installed
	mkdir -p "${CLUSTER}/.state/steps" "${CLUSTER}/auth"
	touch "${CLUSTER}/.state/steps/install"
	echo "apiVersion: v1" >"${CLUSTER}/auth/kubeconfig"
	echo '{"master":[0,1,2],"worker":[0,1,2]}' >"${CLUSTER}/.state/inventory.json"
	ORIG=$(sha256sum "${CLUSTER}/cluster.yaml")
}

@test "node add --dry-run picks the next slots and shows the plan, changes nothing" {
	run "${OKD}" --dir "${CLUSTER}" --dry-run node add --role worker --count 2
	assert_success
	assert_output --partial "Adding 2 node(s) to group worker: small-worker-3 small-worker-4"
	assert_output --partial "would run 'oc adm node-image create'"
	assert_output --partial "Plan: mocked"
	assert_equal "$(sha256sum "${CLUSTER}/cluster.yaml")" "${ORIG}"
	assert_equal "$(cat "${CLUSTER}/.state/inventory.json")" '{"master":[0,1,2],"worker":[0,1,2]}'
	# the plan got the new nodes with the node ISO attached
	assert_equal "$(jq -r '.nodes["small-worker-4"].iso' "${CLUSTER}/tofu/cluster.auto.json")" "$(jq -r '.isos | keys[0]' "${CLUSTER}/tofu/cluster.auto.json")"
}

@test "node add refuses when the group has no spare IPs" {
	yq_set '(.node_groups[] | select(.name == "worker") | .ips) = ["192.0.2.21-192.0.2.23"]'
	run "${OKD}" --dir "${CLUSTER}" --dry-run node add --role worker --count 1
	assert_failure 2
	assert_output --partial "no IP address left"
}

@test "node add --role infra on combined nodes explains the migration path" {
	run "${OKD}" --dir "${CLUSTER}" --dry-run node add --role infra --count 3
	assert_failure 2
	assert_output --partial "Migration path to dedicated infra nodes"
	assert_output --partial "Set taint_infra: true on the new group"
}

@test "node add needs an installed cluster" {
	rm "${CLUSTER}/.state/steps/install"
	run "${OKD}" --dir "${CLUSTER}" node add --role worker --count 1
	assert_failure 1
	assert_output --partial "not installed yet"
}

@test "control-plane nodes are not removed without --force-control-plane" {
	run "${OKD}" --dir "${CLUSTER}" --yes node remove small-master-1
	assert_failure 1
	assert_output --partial "control-plane node; refusing"
}

@test "node remove --dry-run shows a targeted destroy" {
	run "${OKD}" --dir "${CLUSTER}" --dry-run node remove small-worker-1
	assert_success
	assert_output --partial "would cordon and drain small-worker-1"
	run grep -c 'tofu plan .*-destroy -target=module.okd.proxmox_virtual_environment_vm.node\["small-worker-1"\]' "${MOCK_LOG}"
	assert_output 1
}

@test "unknown nodes are rejected" {
	run "${OKD}" --dir "${CLUSTER}" --dry-run node remove nope
	assert_failure 2
	assert_output --partial "nope is not a node of this cluster"
}
