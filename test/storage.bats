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
