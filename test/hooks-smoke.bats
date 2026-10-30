#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Smoke test of every built-in hook against a generic oc mock: no syntax,
# jq or unbound-variable errors, exit code 0 or 2, in both catalog profiles.

setup() {
	load test_helper
	# The real timeout (test/mocks has a network-probe stub of the same name).
	TIMEOUT=$(PATH=/usr/bin:/bin command -v timeout)
	use_mocks
	export PATH="${OKD_PVE_ROOT}/test/mocks/hook-oc:${PATH}"
	export OKD_PVE_LIB_DIR=${OKD_PVE_ROOT}/lib OKD_PVE_BIN=/bin/true OKD_PVE_CLUSTER_DIR=${BATS_TEST_TMPDIR}
	export OKD_PVE_CLUSTER_NAME=small OKD_PVE_BASE_DOMAIN=example.com OKD_PVE_OKD_VERSION=5.0.0-okd-scos.3
	export OKD_PVE_INFRA_TAINT_KEY=node-role.kubernetes.io/infra OKD_PVE_INFRA_TAINT_VALUE=reserved
	export OKD_PVE_INFRA_TAINT_EFFECTS=NoSchedule OKD_PVE_INFRA_NODE_COUNT=3 OKD_PVE_STORAGE_CLASS=example-sc
	export OCLIB_POLL_INTERVAL=1 KUBECONFIG=/dev/null
}

run_hook() {
	run "${TIMEOUT}" -k 2 30 setsid "${OKD_PVE_ROOT}/hooks/$1" </dev/null
	refute_output --partial "jq: error"
	refute_output --partial "syntax error"
	refute_output --partial "unbound variable"
	refute_output --partial "command not found"
	[[ ${status} == 0 || ${status} == 2 ]] || {
		echo "exit ${status}: ${output}" >&2
		return 1
	}
}

@test "every built-in hook runs cleanly (profile redhat)" {
	export OKD_PVE_CATALOG_PROFILE=redhat ALERTMANAGER_WEBHOOK_URL=https://hooks.example.com/alert
	local h
	for h in "${OKD_PVE_ROOT}"/hooks/[0-9]*.sh; do
		[[ ${h##*/} == 10-* ]] && continue # delegates to okd-pve itself
		run_hook "${h##*/}"
	done
}

@test "every built-in hook runs cleanly (profile okderators)" {
	export OKD_PVE_CATALOG_PROFILE=okderators
	local h
	for h in "${OKD_PVE_ROOT}"/hooks/[0-9]*.sh; do
		[[ ${h##*/} == 10-* ]] && continue
		run_hook "${h##*/}"
	done
}

@test "the ingress hook pins routers to infra nodes with tolerations" {
	run_hook 30-ingress-controller.sh
	run grep -o 'patch ingresscontroller/default --type merge -p .*' "${MOCK_LOG}"
	assert_output --partial '"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}}'
	assert_output --partial '"key":"node-role.kubernetes.io/infra","operator":"Equal","value":"reserved","effect":"NoSchedule"'
	assert_output --partial '"replicas":2'
}

@test "the monitoring hook drops fields the operator rejects and retries" {
	local fake=${BATS_TEST_TMPDIR}/bin
	mkdir -p "${fake}"
	cat >"${fake}/oc" <<'SH'
#!/usr/bin/env bash
echo "oc $*" >>"${MOCK_LOG}"
if [[ " $* " == *" --dry-run=server "* ]]; then
	sel=$(yq '.data."config.yaml"' | yq '.prometheusOperatorAdmissionWebhook.nodeSelector // ""')
	if [[ -n ${sel} && ${sel} != '""' ]]; then
		echo 'error unmarshaling: unknown field "prometheusOperatorAdmissionWebhook.nodeSelector"' >&2
		exit 1
	fi
	exit 0
fi
exec "$(dirname "$0")/../../../test/mocks/hook-oc/oc" "$@"
SH
	sed -i "s|\$(dirname \"\$0\")/../../../test/mocks/hook-oc/oc|${OKD_PVE_ROOT}/test/mocks/hook-oc/oc|" "${fake}/oc"
	chmod +x "${fake}/oc"
	PATH=${fake}:${PATH} run_hook 40-monitoring.sh
	assert_output --partial "skipping prometheusOperatorAdmissionWebhook.nodeSelector: not supported by this OKD version"
	assert_output --partial "cluster-monitoring-config applied"
}

@test "the alertmanager hook writes Slack/Mattermost receivers with a critical route" {
	export ALERTMANAGER_WEBHOOK_URL=https://chat.example.com/hooks/secret-token
	export ALERTMANAGER_CHANNEL=alerts ALERTMANAGER_CRITICAL_USERNAME=Critical ALERTMANAGER_PROXY_URL=http://proxy.example.com:3128
	run_hook 45-alertmanager-receiver.sh
	assert_output --partial "Alertmanager receiver configured (slack, channel alerts, via proxy)"
	refute_output --partial "secret-token"
	run yq -o json '.' <(sed -n '/^global:/,/^oc /p' "${MOCK_LOG}" | grep -v '^oc ')
	assert_success
	local cfg=${output}
	run jq -r '[.route.routes[] | "\(.matchers[0])>\(.receiver)"] | join(" ")' <<<"${cfg}"
	assert_output "alertname = Watchdog>watchdog severity = critical>critical"
	run jq -r '.receivers[] | select(.name == "critical") | .slack_configs[0] | "\(.channel) \(.username) \(.link_names) \(.http_config.proxy_url)"' <<<"${cfg}"
	assert_output "alerts Critical true http://proxy.example.com:3128"
	run jq -r '.receivers[] | select(.name == "default") | .slack_configs[0] | "\(.channel) \(.username // "-") \(.api_url)"' <<<"${cfg}"
	assert_output "alerts - https://chat.example.com/hooks/secret-token"
}

@test "the alertmanager hook keeps the plain webhook format on request" {
	export ALERTMANAGER_WEBHOOK_URL=https://hooks.example.com/alert ALERTMANAGER_RECEIVER_TYPE=webhook
	run_hook 45-alertmanager-receiver.sh
	run yq -o json '.' <(sed -n '/^global:/,/^oc /p' "${MOCK_LOG}" | grep -v '^oc ')
	run jq -r '([.receivers[].name] | join(" ")), .receivers[0].webhook_configs[0].url' <<<"${output}"
	assert_output $'default watchdog\nhttps://hooks.example.com/alert'
	export ALERTMANAGER_RECEIVER_TYPE=teams
	run "${OKD_PVE_ROOT}/hooks/45-alertmanager-receiver.sh"
	assert_failure 1
	assert_output --partial "must be slack or webhook"
}

@test "the monitoring hook enables user AlertmanagerConfig and sets UWM Prometheus requests" {
	export MONITORING_UWM_PROMETHEUS_CPU_REQUEST=200m MONITORING_UWM_PROMETHEUS_MEMORY_REQUEST=2Gi
	run_hook 40-monitoring.sh
	run grep -A2 'enableUserAlertmanagerConfig' "${MOCK_LOG}"
	assert_output --partial "enableUserAlertmanagerConfig: true"
	run grep -A3 'requests:' "${MOCK_LOG}"
	assert_output --partial "cpu: 200m"
	assert_output --partial "memory: 2Gi"
}

@test "the ClusterResourceOverride hook omits limitCPUToMemoryPercent when set to 0" {
	export OKD_PVE_CATALOG_PROFILE=redhat CRO_CPU_PERCENT=10 CRO_MEMORY_PERCENT=25 CRO_LIMIT_CPU_TO_MEMORY_PERCENT=0
	run_hook 52-operator-cluster-resource-override.sh
	run grep -o '"podResourceOverride":{"spec":{[^}]*}' <(jq -c . <(sed -n '/^{$/,/^}$/p' "${MOCK_LOG}") 2>/dev/null)
	assert_output '"podResourceOverride":{"spec":{"memoryRequestToLimitPercent":25,"cpuRequestToLimitPercent":10}'
}
