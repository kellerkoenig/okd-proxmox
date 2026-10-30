#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# ClusterResourceOverride operator: derives requests from limits so
# developers only set limits. Only namespaces labeled
# clusterresourceoverrides.admission.autoscaling.openshift.io/enabled=true
# are affected; labeling them is up to the deployment automation.
#
#   CRO_MEMORY_PERCENT               memory request = limit * %, default: 50
#   CRO_CPU_PERCENT                  cpu request = limit * %, default: 25
#   CRO_LIMIT_CPU_TO_MEMORY_PERCENT  cpu limit from memory limit, default: 200;
#                                    0 leaves cpu limits as set by the pod
#
# Not available in the okderators catalog; with that profile set
# OKD_PVE_OP_CLUSTER_RESOURCE_OVERRIDE_PACKAGE/_CHANNEL/_NAMESPACE/_SOURCE.
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

if ! operator_coordinates cluster-resource-override >/dev/null; then
	echo "ClusterResourceOverride is not available in catalog profile $(catalog_profile); skipping." >&2
	exit 2
fi
install_operator_by_key cluster-resource-override

jq -n --argjson mem "${CRO_MEMORY_PERCENT:-50}" --argjson cpu "${CRO_CPU_PERCENT:-25}" \
	--argjson lim "${CRO_LIMIT_CPU_TO_MEMORY_PERCENT:-200}" '{
	apiVersion: "operator.autoscaling.openshift.io/v1",
	kind: "ClusterResourceOverride",
	metadata: {name: "cluster"},
	spec: {podResourceOverride: {spec: ({memoryRequestToLimitPercent: $mem, cpuRequestToLimitPercent: $cpu}
		+ (if $lim == 0 then {} else {limitCPUToMemoryPercent: $lim} end))}}
}' | apply_idempotent -
