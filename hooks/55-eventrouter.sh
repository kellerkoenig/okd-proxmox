#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Event router: writes Kubernetes events to its stdout so the log collector
# stores them like any other log. There is no operator for it; this hook
# deploys the plain manifests, placed on infra nodes.
#
#   EVENTROUTER_NAMESPACE  default: openshift-logging
#   EVENTROUTER_IMAGE      default: profile redhat ->
#                          registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4,
#                          otherwise quay.io/openshift-logging/eventrouter:v0.5.0
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

ns=${EVENTROUTER_NAMESPACE:-openshift-logging}
image=${EVENTROUTER_IMAGE:-}
if [[ -z ${image} ]]; then
	if [[ $(catalog_profile) == redhat ]]; then
		image=registry.redhat.io/openshift-logging/eventrouter-rhel9:v0.4
	else
		image=quay.io/openshift-logging/eventrouter:v0.5.0
	fi
fi
placement='{}'
if ((${OKD_PVE_INFRA_NODE_COUNT:-0} > 0)); then
	placement=$(jq -cn --argjson tol "$(infra_tolerations_json)" \
		'{nodeSelector: {"node-role.kubernetes.io/infra": ""}, tolerations: $tol}')
fi

oc get namespace "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}" >/dev/null
apply_idempotent - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eventrouter
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: okd-pve-event-reader
rules:
  - apiGroups: [""]
    resources: [events]
    verbs: [get, watch, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: okd-pve-event-reader
subjects:
  - kind: ServiceAccount
    name: eventrouter
    namespace: ${ns}
roleRef:
  kind: ClusterRole
  name: okd-pve-event-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: eventrouter
  namespace: ${ns}
data:
  config.json: '{"sink": "stdout"}'
YAML

jq -n --arg ns "${ns}" --arg image "${image}" --argjson p "${placement}" '{
	apiVersion: "apps/v1", kind: "Deployment",
	metadata: {name: "eventrouter", namespace: $ns, labels: {component: "eventrouter"}},
	spec: {
		replicas: 1,
		selector: {matchLabels: {component: "eventrouter"}},
		template: {
			metadata: {labels: {component: "eventrouter"}},
			spec: ({
				serviceAccountName: "eventrouter",
				containers: [{
					name: "eventrouter", image: $image, imagePullPolicy: "IfNotPresent",
					resources: {requests: {cpu: "100m", memory: "128Mi"}, limits: {memory: "128Mi"}},
					securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}},
					volumeMounts: [{name: "config", mountPath: "/etc/eventrouter"}]
				}],
				securityContext: {runAsNonRoot: true, seccompProfile: {type: "RuntimeDefault"}},
				volumes: [{name: "config", configMap: {name: "eventrouter"}}]
			} + $p)
		}
	}}' | apply_idempotent -
oc -n "${ns}" rollout status deployment/eventrouter --timeout=300s
