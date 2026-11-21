#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# okd-pve status (lib/status.sh).

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	PROXMOX_VE_API_TOKEN=${TEST_TOKEN}
	pve_nodes() {
		jq -n '[{node: "pve1", status: "online", cpu: 0.12, maxcpu: 32, mem: 68719476736, maxmem: 412316860416},
			{node: "pve2", status: "online", cpu: 0.05, maxcpu: 32, mem: 34359738368, maxmem: 412316860416},
			{node: "pve3", status: "offline"}]'
	}
	# small-master-2 (planned on pve3) was migrated to pve2, small-worker-2 is missing
	pve_cluster_vms() {
		jq -n '[{vmid: 4100, node: "pve1", status: "running", cpu: 0.2, mem: 8589934592, maxmem: 34359738368},
			{vmid: 4101, node: "pve2", status: "running", cpu: 0.1, mem: 8589934592, maxmem: 34359738368},
			{vmid: 4102, node: "pve2", status: "running", cpu: 0.1, mem: 8589934592, maxmem: 34359738368},
			{vmid: 4120, node: "pve1", status: "stopped", maxmem: 68719476736},
			{vmid: 4121, node: "pve2", status: "running", cpu: 0.3, mem: 17179869184, maxmem: 68719476736},
			{vmid: 999, node: "pve1", status: "running"}]'
	}
	pve_node_storage() {
		jq -n '[{storage: "vm-nfs", used: 1099511627776, total: 4398046511104, shared: 1}, {storage: "local"}]'
	}
	yq_set '.proxmox.vm_storage = "vm-nfs"'
	load_cluster
	STATUS_K8S_NODES='{"small-master-0": "True", "small-master-1": "True", "small-master-2": "True", "small-worker-1": "False"}'
}

@test "status shows the hosts with the cluster's VMs, other VMs are not listed" {
	run status_proxmox
	assert_success
	assert_output --regexp 'pve1 +online +12% of 32 +64/384 GiB +master-0 worker-0'
	assert_output --regexp 'pve2 +online .* master-1 master-2 worker-1'
	assert_output --regexp 'pve3 +offline +- +- +-'
	refute_output --partial 999
}

@test "status marks migrated and missing VMs and their readiness" {
	run status_proxmox
	assert_output --regexp 'small-master-2 +Ready +4102 +running +pve2 \(planned pve3\) +10% +8/32 GiB'
	assert_output --regexp 'small-worker-0 +- +4120 +stopped +pve1 +- +-'
	assert_output --regexp 'small-worker-1 +NotReady +4121 +running +pve2'
	assert_output --regexp 'small-worker-2 +- +4122 +missing +-'
	assert_output --partial "Migrated VMs: small-master-2."
}

@test "status points to storage install after a migration with Proxmox CSI" {
	yq_set '.storage = {"backend": "proxmox-csi", "storage_class": "proxmox"}'
	load_cluster
	run status_proxmox
	assert_output --partial "Run 'okd-pve storage install' to update their topology labels"
}

@test "status shows the VM storage usage" {
	run status_proxmox
	assert_output --partial "Storage vm-nfs: 1024/4096 GiB used (25%), shared"
}

@test "status without Proxmox credentials skips the Proxmox part" {
	unset PROXMOX_VE_API_TOKEN
	run status_proxmox
	assert_success
	assert_output --partial "no credentials (proxmox.conf): skipped"
}

@test "status without a kubeconfig says so instead of failing" {
	run status_cluster
	assert_success
	assert_output --partial "no kubeconfig"
}

@test "age of the last etcd backup" {
	run _status_age "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)"
	assert_output "3h ago"
	run _status_age "$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
	assert_output "3d ago"
}
