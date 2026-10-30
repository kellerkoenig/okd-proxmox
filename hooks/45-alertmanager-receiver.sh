#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Alertmanager receiver, written to the alertmanager-main secret: all alerts
# to a chat or webhook receiver, critical alerts to their own receiver
# (another channel or sender name), the Watchdog alert to a silent receiver.
#
# Type "slack" speaks the Slack incoming webhook format, which Mattermost
# and Rocket.Chat accept as well. Type "webhook" sends Alertmanager's own
# JSON format for receivers that parse it (chat servers do not).
#
# Webhook URL and proxy come only from the environment, never from a file
# in a repository:
#   ALERTMANAGER_WEBHOOK_URL        required; the hook is skipped (warning) without it
#   ALERTMANAGER_PROXY_URL          optional HTTP proxy for the webhook
#   ALERTMANAGER_RECEIVER_TYPE      slack or webhook, default: slack
#   ALERTMANAGER_CHANNEL            slack: channel for all alerts, default: the
#                                   webhook's own channel
#   ALERTMANAGER_CRITICAL_CHANNEL   slack: channel for critical alerts,
#                                   default: ALERTMANAGER_CHANNEL
#   ALERTMANAGER_CRITICAL_USERNAME  slack: sender name for critical alerts,
#                                   default: the webhook's own name
#   ALERTMANAGER_REPEAT_INTERVAL    default: 12h
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

if [[ -z ${ALERTMANAGER_WEBHOOK_URL:-} ]]; then
	echo "ALERTMANAGER_WEBHOOK_URL is not set; skipping the Alertmanager receiver." >&2
	exit 2
fi
type=${ALERTMANAGER_RECEIVER_TYPE:-slack}
if [[ ${type} != slack && ${type} != webhook ]]; then
	echo "ALERTMANAGER_RECEIVER_TYPE must be slack or webhook, not '${type}'." >&2
	exit 1
fi

config=$(jq -n --arg url "${ALERTMANAGER_WEBHOOK_URL}" --arg proxy "${ALERTMANAGER_PROXY_URL:-}" \
	--arg type "${type}" --arg channel "${ALERTMANAGER_CHANNEL:-}" \
	--arg cchannel "${ALERTMANAGER_CRITICAL_CHANNEL:-${ALERTMANAGER_CHANNEL:-}}" \
	--arg cuser "${ALERTMANAGER_CRITICAL_USERNAME:-}" \
	--arg repeat "${ALERTMANAGER_REPEAT_INTERVAL:-12h}" '
	def proxy: if $proxy == "" then {} else {http_config: {proxy_url: $proxy}} end;
	def slack($ch; $user): {
		api_url: $url, send_resolved: true, link_names: true,
		text: "{{ .CommonAnnotations.summary }}\n{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
	} + (if $ch == "" then {} else {channel: $ch} end)
	  + (if $user == "" then {} else {username: $user} end) + proxy;
	{
	global: {resolve_timeout: "5m"},
	inhibit_rules: [
		{source_matchers: ["severity = critical"], target_matchers: ["severity =~ warning|info"], equal: ["namespace", "alertname"]},
		{source_matchers: ["severity = warning"], target_matchers: ["severity = info"], equal: ["namespace", "alertname"]}
	],
	route: {
		group_by: ["namespace", "alertname"],
		group_wait: "30s", group_interval: "5m", repeat_interval: $repeat,
		receiver: "default",
		routes: ([{matchers: ["alertname = Watchdog"], receiver: "watchdog"}]
			+ if $type == "slack" then [{matchers: ["severity = critical"], receiver: "critical"}] else [] end)
	},
	receivers: ((if $type == "slack" then [
		{name: "default", slack_configs: [slack($channel; "")]},
		{name: "critical", slack_configs: [slack($cchannel; $cuser)]}
	] else [
		{name: "default", webhook_configs: [{url: $url, send_resolved: true} + proxy]}
	] end) + [{name: "watchdog"}])
	}' | yq -P '.')

# The URL may contain a token: pass it via stdin, never print it.
oc create secret generic alertmanager-main -n openshift-monitoring \
	--from-file=alertmanager.yaml=/dev/stdin --dry-run=client -o yaml <<<"${config}" |
	apply_idempotent - >/dev/null
echo "Alertmanager receiver configured (${type}${ALERTMANAGER_CHANNEL:+, channel ${ALERTMANAGER_CHANNEL}}$([[ -n ${ALERTMANAGER_PROXY_URL:-} ]] && echo ', via proxy'))."
