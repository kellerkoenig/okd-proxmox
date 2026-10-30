#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Platform monitoring and user workload monitoring: retention, PVCs with the
# configured StorageClass, placement on infra nodes.
#
# The component list in templates/monitoring-components.yaml is complete;
# components that do not exist in this OKD version are skipped instead of
# failing the apply (the cluster-monitoring-operator rejects unknown keys).
#
# This hook owns the ConfigMaps cluster-monitoring-config and
# user-workload-monitoring-config; manual edits are overwritten.
#
#   MONITORING_RETENTION            default: 15d
#   MONITORING_PROMETHEUS_SIZE      default: 50Gi
#   MONITORING_ALERTMANAGER_SIZE    default: 10Gi
#   MONITORING_USER_WORKLOAD        default: true
#   MONITORING_UWM_RETENTION        default: 7d
#   MONITORING_UWM_PROMETHEUS_SIZE  default: 20Gi
#   MONITORING_UWM_THANOS_RULER_SIZE default: 10Gi
#   MONITORING_UWM_PROMETHEUS_CPU_REQUEST     e.g. 200m; default: operator default
#   MONITORING_UWM_PROMETHEUS_MEMORY_REQUEST  e.g. 2Gi; default: operator default
#   MONITORING_USER_ALERTMANAGER_CONFIG  let projects bring their own
#                                   AlertmanagerConfig (routed to the platform
#                                   Alertmanager), default: true
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
components=${here}/templates/monitoring-components.yaml
# Private hook directories may ship their own list next to this hook.
[[ -f ${components} ]] || components=${OKD_PVE_LIB_DIR}/../hooks/templates/monitoring-components.yaml
sc=${OKD_PVE_STORAGE_CLASS:-}
uwm=${MONITORING_USER_WORKLOAD:-true}

placement='{}'
if ((${OKD_PVE_INFRA_NODE_COUNT:-0} > 0)); then
	placement=$(jq -cn --argjson tol "$(infra_tolerations_json)" \
		'{nodeSelector: {"node-role.kubernetes.io/infra": ""}, tolerations: $tol}')
fi

# exists <kind/name> <namespace>
exists() {
	oc get "$1" -n "$2" >/dev/null 2>&1
}

# build <section>: config for platform or user-workload components.
build() {
	local section=$1 ns=$2 cfg='{}' key workload extra
	while IFS=$'\t' read -r key workload extra; do
		if [[ -n ${workload} && ${workload} != - ]] && ! exists "${workload}" "${ns}"; then
			echo "  skipping ${key}: ${workload} does not exist in ${ns} on this OKD version" >&2
			continue
		fi
		cfg=$(jq -c --arg k "${key}" --argjson p "${placement}" --argjson x "${extra}" '.[$k] = ($p + $x)' <<<"${cfg}")
	done < <(yq -o json ".${section}" "${components}" | jq -r --arg sc "${sc}" \
		--arg ret "${MONITORING_RETENTION:-15d}" --arg uret "${MONITORING_UWM_RETENTION:-7d}" \
		--arg psize "${MONITORING_PROMETHEUS_SIZE:-50Gi}" --arg asize "${MONITORING_ALERTMANAGER_SIZE:-10Gi}" \
		--arg upsize "${MONITORING_UWM_PROMETHEUS_SIZE:-20Gi}" --arg tsize "${MONITORING_UWM_THANOS_RULER_SIZE:-10Gi}" '
		def pvc($size): if $sc == "" then {} else {volumeClaimTemplate: {spec: {storageClassName: $sc, resources: {requests: {storage: $size}}}}} end;
		.[] | [.key, (.workload // "-"),
			((if .retention == "platform" then {retention: $ret} elif .retention == "user" then {retention: $uret} else {} end)
			 + (if .pvc == "prometheus" then pvc($psize) elif .pvc == "alertmanager" then pvc($asize)
			    elif .pvc == "uwm-prometheus" then pvc($upsize) elif .pvc == "thanos-ruler" then pvc($tsize) else {} end)
			 | tojson)] | @tsv')
	printf '%s' "${cfg}"
}

# apply_config <namespace> <configmap> <config-json>: validate with a
# server-side dry run first. The monitoring operator rejects fields its
# version does not know (e.g. placement for a component that has none);
# those fields are dropped with a note and the apply is retried.
apply_config() {
	local ns=$1 name=$2 cfg=$3 out fields field
	for _ in 1 2 3 4 5 6 7 8; do
		if out=$(render_cm "${ns}" "${name}" "${cfg}" | oc apply --dry-run=server -f - 2>&1); then
			render_cm "${ns}" "${name}" "${cfg}" | apply_idempotent - >/dev/null
			return 0
		fi
		fields=$(grep -oE 'unknown field \\?"[^"\\]+' <<<"${out}" | sed -E 's/unknown field \\?"//' | sort -u)
		if [[ -z ${fields} ]]; then
			echo "${out}" >&2
			return 1
		fi
		while IFS= read -r field; do
			echo "  skipping ${field}: not supported by this OKD version" >&2
			cfg=$(jq -c --arg f "${field}" 'delpaths([$f | split(".")]) | with_entries(select(.value != {}))' <<<"${cfg}")
		done <<<"${fields}"
	done
	echo "${name}: still rejected after removing unknown fields: ${out}" >&2
	return 1
}

render_cm() {
	oc create configmap "$2" -n "$1" --from-file=config.yaml=<(yq -P '.' <<<"$3") --dry-run=client -o yaml
}

platform=$(build platform openshift-monitoring | jq -c --argjson uwm "${uwm}" \
	--argjson uac "${MONITORING_USER_ALERTMANAGER_CONFIG:-true}" '{enableUserWorkload: $uwm} + .
	| if has("alertmanagerMain") and $uwm and $uac then .alertmanagerMain.enableUserAlertmanagerConfig = true else . end')
apply_config openshift-monitoring cluster-monitoring-config "${platform}"
echo "cluster-monitoring-config applied (StorageClass: ${sc:-none, emptyDir})."

if [[ ${uwm} == true ]]; then
	oc_wait 600 "namespace openshift-user-workload-monitoring" oc get namespace openshift-user-workload-monitoring -o name >/dev/null
	user=$(build user_workload openshift-user-workload-monitoring | jq -c \
		--arg cpu "${MONITORING_UWM_PROMETHEUS_CPU_REQUEST:-}" --arg mem "${MONITORING_UWM_PROMETHEUS_MEMORY_REQUEST:-}" '
		({} + (if $cpu == "" then {} else {cpu: $cpu} end) + (if $mem == "" then {} else {memory: $mem} end)) as $req
		| if has("prometheus") and $req != {} then .prometheus.resources.requests = $req else . end')
	apply_config openshift-user-workload-monitoring user-workload-monitoring-config "${user}"
	echo "user-workload-monitoring-config applied."
fi

wait_for_cluster_operators 1800
