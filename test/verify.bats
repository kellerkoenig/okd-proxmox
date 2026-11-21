#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Cluster health check (lib/verify.sh).

setup() {
	load test_helper
	load_libs
	make_cluster large
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	WORKER=$(nodes_query '[.[] | select(.infra | not) | select(.roles | index("worker"))][0].name')
	export WORKER
	# router pods still on a worker, as after the installation
	oc() {
		jq -n --arg n "${WORKER}" '{items: [{metadata: {name: "router-default-1"}, spec: {nodeName: $n}}]}'
	}
	infra_misplaced_ds_pods() { :; }
}

@test "hook_selected finds built-in hooks with and without extension" {
	run hook_selected 30-ingress-controller
	assert_success
	run hook_selected 30-ingress-controller.sh
	assert_success
	run hook_selected 99-does-not-exist
	assert_failure
	yq_set '.hooks.builtin = ["10-infra-nodes"]'
	load_cluster
	run hook_selected 30-ingress-controller
	assert_failure
}

@test "routers on workers: warning after the hooks" {
	run vf_infra '{"items": []}' 0
	assert_success
	assert_output --partial "[WARN] Ingress router pods not on infra nodes: router-default-1@${WORKER}"
}

@test "routers on workers: skipped before the hooks when 30-ingress-controller runs" {
	run vf_infra '{"items": []}' 1
	assert_success
	assert_output --partial "[SKIP] Ingress router placement (hook 30-ingress-controller moves the routers to the infra nodes)"
	refute_output --partial "[WARN] Ingress router"
}

@test "routers on workers: warning before the hooks when 30-ingress-controller is not selected" {
	yq_set '.hooks.builtin = ["10-infra-nodes"]'
	load_cluster
	run vf_infra '{"items": []}' 1
	assert_output --partial "[WARN] Ingress router pods not on infra nodes"
}
