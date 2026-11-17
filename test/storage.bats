#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Storage backends (lib/storage.sh): upstream manifests.

setup() {
	load test_helper
	load_libs
	make_cluster small
	LOG_FILE=${BATS_TEST_TMPDIR}/test.log
	load_cluster
	STORAGE_MANIFESTS=${BATS_TEST_TMPDIR}/manifests
	mkdir -p "${STORAGE_MANIFESTS}"
	# an upstream manifest: namespace, node plugin, controller, binding
	fetch() {
		cat >"$2" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: upstream
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-node
  namespace: upstream
spec:
  template:
    spec:
      tolerations:
        - {key: node.kubernetes.io/disk-pressure, operator: Exists, effect: NoSchedule}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-controller
  namespace: upstream
spec:
  template:
    spec: {}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: csi
subjects:
  - {kind: ServiceAccount, name: csi, namespace: upstream}
YAML
	}
}

_manifest() {
	cat "${STORAGE_MANIFESTS}"/*.yaml
}

@test "upstream manifests move into the namespace; without tainted infra nodes nothing is added" {
	storage_fetch_manifest https://example.com/csi.yaml csi
	run _manifest
	refute_output --partial "kind: Namespace"
	assert_equal "$(_manifest | yq -r 'select(.kind == "DaemonSet") | .metadata.namespace')" csi
	assert_equal "$(_manifest | yq -r 'select(.kind == "ClusterRoleBinding") | .subjects[0].namespace')" csi
	assert_equal "$(_manifest | yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations | length')" 1
}

@test "with tainted infra nodes the CSI node plugin tolerates the infra taint, the controller does not" {
	yq_set '(.node_groups[] | select(.name == "worker") | .taint_infra) = true'
	load_cluster
	storage_fetch_manifest https://example.com/csi.yaml csi
	assert_equal "$(_manifest | yq -o json -I0 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations')" \
		'[{"key":"node.kubernetes.io/disk-pressure","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/infra","operator":"Equal","value":"reserved","effect":"NoSchedule"}]'
	assert_equal "$(_manifest | yq -r 'select(.kind == "Deployment") | .spec.template.spec.tolerations')" null
}

@test "a failed storage test shows the warnings of the test PVC and pod" {
	oc() {
		[[ "$*" == "get events -n okd-pve-storage-test -o json" ]] || return 0
		jq -n '{items: [
			{type: "Normal", reason: "WaitForFirstConsumer", message: "waiting", involvedObject: {kind: "PersistentVolumeClaim", name: "okd-pve-test"}, lastTimestamp: "2026-11-13T08:00:00Z"},
			{type: "Warning", reason: "ProvisioningFailed", message: "error generating accessibility requirements: no topology key found for node small-worker-0",
			 involvedObject: {kind: "PersistentVolumeClaim", name: "okd-pve-test"}, lastTimestamp: "2026-11-13T08:01:00Z"}]}'
	}
	run storage_test_reasons okd-pve-storage-test
	assert_output --partial "WARN PersistentVolumeClaim okd-pve-test: ProvisioningFailed: error generating accessibility requirements: no topology key found for node small-worker-0"
	refute_output --partial "WaitForFirstConsumer"
}

@test "a StorageClass with changed parameters is deleted so it can be created again" {
	export OC_CALLS=${BATS_TEST_TMPDIR}/oc-calls
	: >"${OC_CALLS}"
	oc() {
		case "$*" in
		"get storageclass okd-pve -o json")
			echo '{"metadata": {"name": "okd-pve"}, "provisioner": "csi.proxmox.sinextra.dev", "reclaimPolicy": "Delete",
				"volumeBindingMode": "WaitForFirstConsumer", "parameters": {"csi.storage.k8s.io/fstype": "xfs", "ssd": "true"}}'
			;;
		"get storageclass "*) return 1 ;;
		*) echo "$*" >>"${OC_CALLS}" ;;
		esac
	}
	local sc='{"kind": "StorageClass", "metadata": {"name": "okd-pve"}, "provisioner": "csi.proxmox.sinextra.dev",
		"volumeBindingMode": "WaitForFirstConsumer", "parameters": {"csi.storage.k8s.io/fstype": "ext4", "ssd": true}}'
	run storage_sc_recreate_if_changed "${sc}"
	assert_output --partial "StorageClass okd-pve: parameters changed, deleted and created again"
	assert_equal "$(cat "${OC_CALLS}")" "delete storageclass okd-pve"
	# unchanged (ssd true vs "true" is the same): nothing happens
	: >"${OC_CALLS}"
	run storage_sc_recreate_if_changed "${sc//ext4/xfs}"
	refute_output
	assert_equal "$(cat "${OC_CALLS}")" ""
	# a class that does not exist yet is left to the apply
	run storage_sc_recreate_if_changed '{"kind": "StorageClass", "metadata": {"name": "new"}, "provisioner": "x"}'
	refute_output
}
