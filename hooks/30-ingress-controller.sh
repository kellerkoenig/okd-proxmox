#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Default IngressController: replicas, placement on infra nodes (with
# tolerations for the infra taint), header buffer tuning, HTTP/2.
#
#   INGRESS_REPLICAS                         default: 2 (capped at #infra nodes)
#   INGRESS_HEADER_BUFFER_BYTES              default: 32768
#   INGRESS_HEADER_BUFFER_MAX_REWRITE_BYTES  default: 8192
#   INGRESS_HTTP2                            default: true
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

replicas=${INGRESS_REPLICAS:-2}
infra=${OKD_PVE_INFRA_NODE_COUNT:-0}
if ((infra > 0 && replicas > infra)); then
	echo "INGRESS_REPLICAS=${replicas} but only ${infra} infra node(s); using ${infra}."
	replicas=${infra}
fi

placement='{}'
if ((infra > 0)); then
	placement=$(jq -cn --argjson tol "$(infra_tolerations_json)" '{
		nodeSelector: {matchLabels: {"node-role.kubernetes.io/infra": ""}},
		tolerations: $tol}')
fi
patch=$(jq -cn --argjson r "${replicas}" --argjson p "${placement}" \
	--argjson hb "${INGRESS_HEADER_BUFFER_BYTES:-32768}" \
	--argjson hm "${INGRESS_HEADER_BUFFER_MAX_REWRITE_BYTES:-8192}" '{spec: ({
		replicas: $r,
		tuningOptions: {headerBufferBytes: $hb, headerBufferMaxRewriteBytes: $hm}
	} + (if $p == {} then {} else {nodePlacement: $p} end))}')
patch_merge ingresscontroller/default "${patch}" -n openshift-ingress-operator

if [[ ${INGRESS_HTTP2:-true} == true ]]; then
	oc annotate ingresses.config/cluster ingress.operator.openshift.io/default-enable-http2=true --overwrite >/dev/null
	echo "HTTP/2 enabled for all routes (ingresses.config/cluster)."
fi

oc_wait 900 "router-default rollout" bash -c '
	d=$(oc -n openshift-ingress get deployment router-default -o json) &&
	jq -e ".status.updatedReplicas == .spec.replicas and .status.availableReplicas == .spec.replicas and (.status.unavailableReplicas // 0) == 0" <<<"$d" >/dev/null'
echo "Ingress: ${replicas} router replica(s)$( ((infra > 0)) && echo ' on infra nodes')."
