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

@test "upstream manifests move into the namespace; node plugins tolerate the control plane" {
	storage_fetch_manifest https://example.com/csi.yaml csi
	run _manifest
	refute_output --partial "kind: Namespace"
	assert_equal "$(_manifest | yq -r 'select(.kind == "DaemonSet") | .metadata.namespace')" csi
	assert_equal "$(_manifest | yq -r 'select(.kind == "ClusterRoleBinding") | .subjects[0].namespace')" csi
	assert_equal "$(_manifest | yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations[].key' | paste -sd' ' -)" \
		"node.kubernetes.io/disk-pressure node-role.kubernetes.io/master node-role.kubernetes.io/control-plane"
}

@test "with tainted infra nodes the CSI node plugin tolerates the infra taint, the controller does not" {
	yq_set '(.node_groups[] | select(.name == "worker") | .taint_infra) = true'
	load_cluster
	storage_fetch_manifest https://example.com/csi.yaml csi
	assert_equal "$(_manifest | yq -o json -I0 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations')" \
		'[{"key":"node.kubernetes.io/disk-pressure","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/infra","operator":"Equal","value":"reserved","effect":"NoSchedule"}]'
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

# PVs of a cluster with Proxmox CSI: shared storage (empty zone), one local
# volume, one Retain volume and a volume of another driver.
_pvs() {
	jq -n '{items: [
		{metadata: {name: "pvc-1"}, spec: {persistentVolumeReclaimPolicy: "Delete", claimRef: {namespace: "openshift-monitoring", name: "prometheus-0"},
			csi: {driver: "csi.proxmox.sinextra.dev", volumeHandle: "small//vm-nfs/vm-9999-pvc-1.raw"}}},
		{metadata: {name: "pvc-2"}, spec: {persistentVolumeReclaimPolicy: "Delete", claimRef: {namespace: "app", name: "data"},
			csi: {driver: "csi.proxmox.sinextra.dev", volumeHandle: "small/pve2/local-lvm/vm-9999-pvc-2"}}},
		{metadata: {name: "pvc-3"}, spec: {persistentVolumeReclaimPolicy: "Retain", claimRef: {namespace: "openshift-etcd-backup", name: "etcd-backup"},
			csi: {driver: "csi.proxmox.sinextra.dev", volumeHandle: "small//vm-nfs/vm-9999-pvc-3.raw"}}},
		{metadata: {name: "nfs-1"}, spec: {persistentVolumeReclaimPolicy: "Delete", nfs: {server: "192.0.2.200", path: "/x"}}}]}'
}

_csi_destroy_setup() {
	yq_set '.storage = {"backend": "proxmox-csi", "storage_class": "okd-pve"}'
	load_cluster
	oc() { [[ "$*" == "get pv -o json --request-timeout=20s" ]] && _pvs; }
	PROXMOX_CSI_TOKEN='kubernetes-csi@pve!csi=66666666-7777-8888-9999-000000000000'
	PROXMOX_VE_API_TOKEN=${TEST_TOKEN}
	PROXMOX_VE_ENDPOINT=https://pve.example.com:8006/
	DELETES=${BATS_TEST_TMPDIR}/deletes
	: >"${DELETES}"
	pve_api() { echo "${PROXMOX_VE_API_TOKEN%%=*} $1 $2 $3" >>"${DELETES}"; echo '"UPID:pve1:1"'; }
	pve_task_wait() { :; }
}

@test "the Proxmox CSI volumes of the cluster come from its PersistentVolumes" {
	_csi_destroy_setup
	run storage_csi_volumes_json
	assert_success
	assert_equal "$(jq -r '.[] | "\(.pv) \(.policy) \(.zone) \(.storage) \(.disk) \(.claim)"' <<<"${output}")" \
		"pvc-1 Delete  vm-nfs vm-9999-pvc-1.raw openshift-monitoring/prometheus-0
pvc-2 Delete pve2 local-lvm vm-9999-pvc-2 app/data
pvc-3 Retain  vm-nfs vm-9999-pvc-3.raw openshift-etcd-backup/etcd-backup"
}

@test "destroy deletes the Delete volumes with the CSI token and keeps the retained ones" {
	_csi_destroy_setup
	STORAGE_CSI_VOLUMES=$(storage_csi_volumes_json)
	run storage_csi_volumes_after_destroy
	assert_success
	assert_output --partial "Deleted 2 Proxmox CSI volume(s)"
	assert_output --partial "Proxmox CSI volumes kept: vm-nfs:vm-9999-pvc-3.raw (openshift-etcd-backup/etcd-backup)"
	assert_output --partial "destroy --delete-retained-volumes' deletes them too"
	run cat "${DELETES}"
	assert_line --index 0 "kubernetes-csi@pve!csi /nodes/pve1/storage/vm-nfs/content/vm-nfs%3Avm-9999-pvc-1.raw -X DELETE"
	assert_line --index 1 "kubernetes-csi@pve!csi /nodes/pve2/storage/local-lvm/content/local-lvm%3Avm-9999-pvc-2 -X DELETE"
	assert_equal "${#lines[@]}" 2
}

@test "destroy counts a volume that no longer exists as gone, not as a failure" {
	_csi_destroy_setup
	STORAGE_CSI_VOLUMES=$(storage_csi_volumes_json)
	# pvc-2 was deleted after the backup a restore came from: its task fails
	pve_api() {
		echo "${PROXMOX_VE_API_TOKEN%%=*} $1 $2 $3" >>"${DELETES}"
		case $1 in
		*content\?vmid=9999) echo '[{"volid": "vm-nfs:vm-9999-pvc-1.raw"}]' ;;
		*) echo '"UPID:pve1:1"' ;;
		esac
	}
	pve_task_wait() {
		[[ $(tail -n 1 "${DELETES}") == *pvc-2* ]] || return 0
		_pve_error "task failed: lvremove error: Failed to find logical volume"
		return 1
	}
	run storage_csi_volumes_after_destroy
	assert_success
	assert_output --partial "Deleted 1 Proxmox CSI volume(s)"
	assert_output --partial "1 Proxmox CSI volume(s) of the cluster no longer existed on the storage"
	refute_output --partial "Could not delete"
	refute_output --partial "after checking"
}

@test "destroy keeps a volume whose delete fails while it still exists" {
	_csi_destroy_setup
	STORAGE_CSI_VOLUMES=$(storage_csi_volumes_json)
	pve_api() {
		echo "${PROXMOX_VE_API_TOKEN%%=*} $1 $2 $3" >>"${DELETES}"
		case $1 in
		*content\?vmid=9999) echo '[{"volid": "local-lvm:vm-9999-pvc-2"}]' ;;
		*pvc-2*) _pve_error "HTTP 500: volume is busy"; return 1 ;;
		*) echo '"UPID:pve1:1"' ;;
		esac
	}
	run storage_csi_volumes_after_destroy
	assert_output --partial "Could not delete local-lvm:vm-9999-pvc-2 (app/data): HTTP 500: volume is busy"
	assert_output --partial "Delete them in the Proxmox UI after checking."
}

@test "destroy --delete-retained-volumes deletes the retained volumes too" {
	_csi_destroy_setup
	STORAGE_CSI_VOLUMES=$(storage_csi_volumes_json)
	run storage_csi_volumes_after_destroy --delete-retained
	assert_output --partial "Deleted 3 Proxmox CSI volume(s)"
	refute_output --partial "kept"
}

@test "without the CSI token destroy keeps the volumes and says so" {
	_csi_destroy_setup
	STORAGE_CSI_VOLUMES=$(storage_csi_volumes_json)
	unset PROXMOX_CSI_TOKEN
	run storage_csi_volumes_after_destroy
	assert_output --partial "No PROXMOX_CSI_TOKEN"
	run cat "${DELETES}"
	assert_output ""
}

@test "destroy without API warns that the CSI volumes stay" {
	_csi_destroy_setup
	oc() { return 1; }
	touch "${KUBECONFIG_FILE}" 2>/dev/null || { mkdir -p "$(dirname "${KUBECONFIG_FILE}")" && touch "${KUBECONFIG_FILE}"; }
	cluster_api_init_any() { :; }
	run storage_csi_volumes_before_destroy
	assert_output --partial "cannot be determined and stay on the storage"
}

@test "destroy finds the CSI volumes with an oc of the old version after okd.version changed" {
	_csi_destroy_setup
	mkdir -p "$(dirname "${KUBECONFIG_FILE}")" "${BIN_DIR}"
	touch "${KUBECONFIG_FILE}"
	cat >"${BIN_DIR}/oc" <<'SH'
#!/bin/sh
echo '{"releaseClientVersion": "4.22.0-okd-scos.10"}'
SH
	chmod +x "${BIN_DIR}/oc"
	_candidates() { echo "${BIN_DIR}/oc"; }
	yq_set '.okd.version = "5.0.0-okd-scos.8"'
	load_cluster
	oc() { [[ "$*" == "get pv -o json --request-timeout=20s" ]] && _pvs; }
	run tool_check oc
	assert_failure
	storage_csi_volumes_before_destroy
	assert_equal "$(jq -r 'map(.pv) | join(" ")' <<<"${STORAGE_CSI_VOLUMES}")" "pvc-1 pvc-2 pvc-3"
	assert_equal "${OC}" "${BIN_DIR}/oc"
}
