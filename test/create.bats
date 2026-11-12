#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# The create state machine: all steps, idempotent resume, refusal to rebuild
# the ISO for a changed configuration. openshift-install, tofu and the
# Proxmox API are mocked; cluster-side steps are stubbed.

setup() {
	load test_helper
	use_mocks
	command -v butane >/dev/null || skip "butane not installed"
	export NO_COLOR=1 OKD_PVE_STATUS_INTERVAL=1
	# shellcheck source=../okd-pve
	source "${OKD_PVE_ROOT}/okd-pve"
	# okd-pve turns on nounset; the bats helpers do not expect it. errexit
	# stays on, otherwise a failed assertion before the last line of a test
	# would go unnoticed.
	set +u
	make_cluster small
	write_proxmox_conf
	# Cluster-side steps are covered elsewhere; stub them here.
	preflight_run() { echo "preflight stub"; }
	cluster_api_init() { :; }
	nodes_reconcile_labels() { echo "labels stub"; }
	verify_once() { echo "verify stub"; }
	cmd_storage_install() { echo "storage stub"; }
	hooks_run() { echo "hooks stub"; }
	tool_check() { printf '%s\t%s\n' "$(command -v "$1")" mock; }
	ORIG_IC=$(sha256sum "${CLUSTER}/install-config.yaml")
}

create() {
	run main --dir "${CLUSTER}" --yes "$@" create
}

applies() {
	find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'apply-*.json' | sort
}

@test "create runs every step and leaves the source files untouched" {
	create
	assert_success
	assert_output --partial "[14/14] Post-Install hooks"
	assert_output --partial "is ready"
	assert_equal "$(sha256sum "${CLUSTER}/install-config.yaml")" "${ORIG_IC}"
	assert [ -f "${CLUSTER}/.generated/agent.x86_64.iso" ]
	assert_equal "$(stat -c %a "${CLUSTER}/auth/kubeadmin-password")" 600
	local s
	for s in image vms bootstrap install iso-detached labels verified hooks; do
		assert [ -f "${CLUSTER}/.state/steps/${s}" ]
	done
	# first apply attaches the agent ISO to every node, second detaches it
	local first second
	first=$(applies | head -n1)
	second=$(applies | tail -n1)
	assert_equal "$(jq -r '[.nodes[].iso] | unique | join(",")' "${first}")" agent
	assert_equal "$(jq -r '.isos | keys | join(",")' "${first}")" agent
	assert_equal "$(jq -r '[.nodes[].iso] | unique | join(",")' "${second}")" ""
	assert_equal "$(jq -r '.isos | length' "${second}")" 0
	run grep -c 'agent create image' "${MOCK_LOG}"
	assert_output 1
}

@test "a second create run skips everything that is done" {
	create
	assert_success
	: >"${MOCK_LOG}"
	create
	assert_success
	run grep -c 'openshift-install agent' "${MOCK_LOG}"
	assert_output 0
	run grep -c 'tofu apply' "${MOCK_LOG}"
	assert_output 0
}

@test "an openshift-install timeout is a warning that says to start create again" {
	export MOCK_WAIT_FAIL=bootstrap-complete MOCK_WAIT_TIMEOUT=1
	create
	assert_failure 1
	assert_output --partial "WARN openshift-install stopped waiting for bootstrap after its fixed timeout"
	assert_output --partial "nodes answer ping"
	assert_output --partial "Next step: start 'okd-pve create' again. It skips the ISO and the VMs"
	assert_output --partial "If it times out again without progress: Check the rendezvous node console"
	refute_output --partial "ERROR"
	run grep -c "\[HINT\] Next step: start 'okd-pve create' again" "${CLUSTER}"/logs/latest.log
	assert_output 1
	unset MOCK_WAIT_FAIL MOCK_WAIT_TIMEOUT
}

@test "an interrupted install resumes at the step that failed" {
	export MOCK_WAIT_FAIL=bootstrap-complete
	create
	assert_failure 1
	assert_output --partial "Bootstrap did not complete"
	assert [ -f "${CLUSTER}/.state/steps/vms" ]
	assert [ ! -f "${CLUSTER}/.state/steps/bootstrap" ]
	unset MOCK_WAIT_FAIL
	: >"${MOCK_LOG}"
	create
	assert_success
	run grep -c 'agent create image' "${MOCK_LOG}"
	assert_output 0
	run grep -c 'wait-for bootstrap-complete' "${MOCK_LOG}"
	assert_output 1
	assert_equal "$(applies | wc -l | tr -d ' ')" 2
}

@test "a configuration change after the ISO was built is refused" {
	export MOCK_WAIT_FAIL=bootstrap-complete
	create
	assert_failure 1
	unset MOCK_WAIT_FAIL
	yq_set '.network.ntp_servers = ["192.0.2.200", "192.0.2.201", "192.0.2.202"]'
	create
	assert_failure 2
	assert_output --partial "configuration changed after the agent ISO was built"
}

@test "an ISO older than iso_max_age_hours is rebuilt while no VM exists" {
	export MOCK_TOFU_FAIL=apply
	create
	assert_failure 1
	assert [ -f "${CLUSTER}/.state/steps/image" ]
	assert [ ! -f "${CLUSTER}/.state/steps/vms" ]
	touch -d '25 hours ago' "${CLUSTER}/.generated/agent.x86_64.iso"
	create
	assert_failure 1
	assert_output --partial "The agent ISO is 25h old"
	run grep -c 'agent create image' "${MOCK_LOG}"
	assert_output 2
	# a fresh ISO is reused
	create
	run grep -c 'agent create image' "${MOCK_LOG}"
	assert_output 2
}

@test "a configuration change before any VM exists rebuilds the ISO" {
	export MOCK_TOFU_FAIL=apply
	create
	assert_failure 1
	yq_set '.network.ntp_servers = ["192.0.2.200", "192.0.2.201", "192.0.2.202"]'
	create
	assert_output --partial "rebuilding it (no VM uses it yet)"
	run grep -c 'agent create image' "${MOCK_LOG}"
	assert_output 2
}

@test "changed node counts after the VMs exist are refused" {
	export MOCK_WAIT_FAIL=bootstrap-complete
	create
	unset MOCK_WAIT_FAIL
	yq_set '(.node_groups[] | select(.name == "worker") | .count) = 4'
	create
	assert_failure 2
	assert_output --partial "Scale an installed cluster with 'okd-pve node add/remove'"
}

@test "destroy removes state but keeps the configuration" {
	create
	assert_success
	run main --dir "${CLUSTER}" --yes destroy
	assert_success
	assert [ ! -e "${CLUSTER}/.state" ]
	assert [ ! -e "${CLUSTER}/.generated" ]
	assert [ ! -e "${CLUSTER}/auth" ]
	assert [ -f "${CLUSTER}/cluster.yaml" ]
	assert [ -f "${CLUSTER}/install-config.yaml" ]
	assert [ -f "${CLUSTER}/proxmox.conf" ]
}

@test "destroy works after cluster.yaml was changed for the next build" {
	create
	assert_success
	# a dedicated infra group before the workers moves their VMIDs
	yq_set '.proxmox.spread = "balanced" | .node_groups |= [.[0], {"name": "infra", "roles": ["infra"], "taint_infra": true,
		"count": 3, "cpu": 8, "memory_gib": 32, "disk_gib": 120, "ips": ["192.0.2.31-192.0.2.33"]}, .[1]]'
	run main --dir "${CLUSTER}" --yes destroy
	assert_success
	refute_output --partial "would recreate existing VMs"
	assert_output --partial "VMs in state: small-master-0"
	assert [ ! -e "${CLUSTER}/.state" ]
}

@test "with registry mirrors, create sets the mirror policy once after the installation" {
	yq_set '.registry_mirrors.registries = [{"source": "quay.io", "mirror": "quay-cache.example.com"}] | .storage.backend = "none"'
	mirrors_cluster_sync() { echo "mirror policy stub"; }
	create
	assert_success
	assert_output --partial "[11/14] Infra labels, taints and registry mirror policy"
	assert_output --partial "mirror policy stub"
	assert [ -f "${CLUSTER}/.state/steps/mirror-policy" ]
	create
	assert_success
	refute_output --partial "mirror policy stub"
}
