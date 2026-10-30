#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Internal image registry: on bare metal/Proxmox it starts as "Removed"
# because there is no default storage. This hook enables it with a PVC on the
# configured StorageClass and places it on infra nodes.
#
#   REGISTRY_SIZE           default: 100Gi
#   REGISTRY_STORAGE_CLASS  default: the StorageClass passed to hooks
#   REGISTRY_ACCESS_MODE    ReadWriteOnce (1 replica, Recreate) or
#                           ReadWriteMany (2 replicas); default: ReadWriteOnce
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

sc=${REGISTRY_STORAGE_CLASS:-${OKD_PVE_STORAGE_CLASS:-}}
if [[ -z ${sc} ]]; then
	echo "No StorageClass configured for the registry; leaving it Removed." >&2
	exit 2
fi
mode=${REGISTRY_ACCESS_MODE:-ReadWriteOnce}

apply_idempotent - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  storageClassName: ${sc}
  accessModes: [${mode}]
  resources:
    requests:
      storage: ${REGISTRY_SIZE:-100Gi}
YAML

placement='{}'
if ((${OKD_PVE_INFRA_NODE_COUNT:-0} > 0)); then
	placement=$(jq -cn --argjson tol "$(infra_tolerations_json)" \
		'{nodeSelector: {"node-role.kubernetes.io/infra": ""}, tolerations: $tol}')
fi
patch=$(jq -cn --arg mode "${mode}" --argjson p "${placement}" '{spec: ({
	managementState: "Managed",
	storage: {pvc: {claim: "image-registry-storage"}},
	replicas: (if $mode == "ReadWriteMany" then 2 else 1 end),
	rolloutStrategy: (if $mode == "ReadWriteMany" then "RollingUpdate" else "Recreate" end)
} + $p)}')
patch_merge configs.imageregistry.operator.openshift.io/cluster "${patch}"
oc_wait 900 "image registry to be available" bash -c \
	'[[ $(oc get co image-registry -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}") == True ]]'
echo "Image registry enabled on ${sc} (${mode})."
