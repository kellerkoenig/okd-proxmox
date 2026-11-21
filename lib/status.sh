# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# okd-pve status: one screen with the state of the cluster and of its VMs
# on Proxmox. Read-only; every part that cannot be reached is reported and
# skipped, so it also works while the API or Proxmox is down.

[[ -n ${_OKD_PVE_STATUS_LOADED:-} ]] && return 0
_OKD_PVE_STATUS_LOADED=1

# Alerts that always fire or only inhibit others.
STATUS_IGNORED_ALERTS='["Watchdog", "InfoInhibitor", "AlertmanagerReceiversNotConfigured"]'

_status_row() {
	printf '    %-14s %s\n' "$1" "$2"
}

# _status_age <iso-time>: "3h ago", "2d ago".
_status_age() {
	local t s
	t=$(date -d "$1" +%s 2>/dev/null) || {
		printf '%s' "$1"
		return
	}
	s=$(($(date +%s) - t))
	if ((s < 3600)); then
		printf '%dm ago' $((s / 60))
	elif ((s < 172800)); then
		printf '%dh ago' $((s / 3600))
	else
		printf '%dd ago' $((s / 86400))
	fi
}

# status_cluster: version, nodes, operators, alerts, storage, etcd backup.
# Sets STATUS_K8S_NODES (JSON object name -> ready) for the node table.
STATUS_K8S_NODES='{}'
status_cluster() {
	log_step "Cluster ${CLUSTER_NAME}.${BASE_DOMAIN}"
	if [[ ! -f ${KUBECONFIG_FILE} ]]; then
		_status_row "API" "no kubeconfig (${KUBECONFIG_FILE}); not installed yet?"
		return 0
	fi
	cluster_api_init
	local nodes
	if ! nodes=$(oc get nodes -o json --request-timeout=15s 2>/dev/null); then
		_status_row "API" "${C_RED}not reachable${C_RESET} (api.${CLUSTER_NAME}.${BASE_DOMAIN})"
		return 0
	fi
	STATUS_K8S_NODES=$(jq -c '[.items[] | {key: .metadata.name,
		value: ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown")}] | from_entries' <<<"${nodes}")

	local cv
	cv=$(oc get clusterversion version -o json 2>/dev/null || echo '{}')
	_status_row "Version" "$(jq -r '
		(.status.desired.version // "unknown") as $v
		| ([.status.conditions[]? | select(.type == "Progressing" and .status == "True")] | length > 0) as $p
		| if $p then "\($v), updating: \([.status.conditions[]? | select(.type == "Progressing") | .message][0])" else $v end' <<<"${cv}")"
	_status_row "API" "${C_GREEN}ok${C_RESET}"
	_status_row "Nodes" "$(jq -r '[.[] | select(. == "True")] | length' <<<"${STATUS_K8S_NODES}")/$(jq -r 'length' <<<"${STATUS_K8S_NODES}") Ready"

	_status_row "Operators" "$(oc get clusteroperators -o json 2>/dev/null | jq -r '
		def c($t): [.status.conditions[]? | select(.type == $t and .status == "True")] | length > 0;
		[.items[] | {name: .metadata.name, a: c("Available"), d: c("Degraded"), p: c("Progressing")}] as $o
		| "\([$o[] | select(.a)] | length)/\($o | length) available"
		+ (if any($o[]; .d) then ", degraded: \([$o[] | select(.d) | .name] | join(" "))" else "" end)
		+ (if any($o[]; .p) then ", progressing: \([$o[] | select(.p) | .name] | join(" "))" else "" end)' || echo unknown)"

	local alerts
	alerts=$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 --request-timeout=20s -- \
		curl -s --max-time 10 http://localhost:9090/api/v1/alerts 2>/dev/null |
		jq -r --argjson ign "${STATUS_IGNORED_ALERTS}" '
			[.data.alerts[] | select(.state == "firing" and (.labels.alertname as $a | $ign | index($a) | not))]
			| group_by(.labels.alertname)
			| map("\(.[0].labels.alertname) (\(.[0].labels.severity // "none")\(if length > 1 then ", \(length)x" else "" end))")
			| if length == 0 then "none firing" else join(", ") end' 2>/dev/null) || alerts=''
	_status_row "Alerts" "${alerts:-not available (Prometheus not reachable)}"

	local sc pvcs
	sc=$(oc get storageclass -o json 2>/dev/null | jq -r '[.items[]
		| select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name][0] // "none"')
	pvcs=$(oc get pvc -A -o json 2>/dev/null | jq -r '[.items[].status.phase] | group_by(.) | map("\(length) \(.[0] | ascii_downcase)") | join(", ")')
	_status_row "Storage" "default class ${sc}; PVCs: ${pvcs:-none}"

	local cj
	if cj=$(oc -n "${ETCD_BACKUP_NS}" get cronjob etcd-backup -o json 2>/dev/null); then
		local last
		last=$(jq -r '.status.lastSuccessfulTime // empty' <<<"${cj}")
		if [[ -n ${last} ]]; then
			_status_row "etcd backup" "last $(date -d "${last}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${last}") ($(_status_age "${last}")), schedule '$(jq -r '.spec.schedule' <<<"${cj}")'"
		else
			_status_row "etcd backup" "${C_YELLOW}no successful backup yet${C_RESET}"
		fi
	else
		_status_row "etcd backup" "not set up (hook 56-etcd-backup)"
	fi
}

# status_proxmox: hosts, the cluster's VMs (actual vs. planned host) and the
# VM storage.
status_proxmox() {
	log_step "Proxmox"
	if [[ -z ${PROXMOX_VE_API_TOKEN:-} ]]; then
		_status_row "Proxmox" "no credentials (proxmox.conf): skipped"
		return 0
	fi
	local hosts vms
	if ! hosts=$(pve_nodes) || ! vms=$(pve_cluster_vms); then
		_status_row "Proxmox" "${C_RED}not reachable${C_RESET}: ${PVE_API_ERROR:-}"
		return 0
	fi
	local planned
	planned=$(nodes_json)
	{
		echo "HOST|STATUS|CPU|MEMORY|CLUSTER VMS"
		jq -r --argjson vms "${vms}" --argjson plan "${planned}" --arg prefix "${CLUSTER_NAME}-" '
			($plan | map({key: (.vmid | tostring), value: .name}) | from_entries) as $ours
			| sort_by(.node)[]
			| .node as $h
			| [$h, .status,
			   (if .status == "online" then "\((.cpu // 0) * 100 | floor)% of \(.maxcpu)" else "-" end),
			   (if .status == "online" then "\(((.mem // 0) / 1073741824) | floor)/\(((.maxmem // 0) / 1073741824) | floor) GiB" else "-" end),
			   ([$vms[] | select(.node == $h and $ours[.vmid | tostring]) | $ours[.vmid | tostring] | ltrimstr($prefix)] | sort | join(" ") | if . == "" then "-" else . end)]
			| join("|")' <<<"${hosts}"
	} | column -t -s '|' | sed 's/^/    /'

	echo
	local moved
	{
		echo "NODE|READY|VM|VM STATUS|HOST|CPU|MEMORY"
		jq -r --argjson vms "${vms}" --argjson k8s "${STATUS_K8S_NODES}" '
			($vms | map({key: (.vmid | tostring), value: .}) | from_entries) as $v
			| .[] | $v[.vmid | tostring] as $vm
			| [.name,
			   ($k8s[.name] // "-" | if . == "True" then "Ready" elif . == "-" then "-" else "NotReady" end),
			   (.vmid | tostring),
			   ($vm.status // "missing"),
			   (if $vm == null then "-" elif $vm.node == .host then $vm.node else "\($vm.node) (planned \(.host))" end),
			   (if $vm.status == "running" then "\((($vm.cpu // 0) * 100) | floor)%" else "-" end),
			   (if $vm.status == "running" then "\((($vm.mem // 0) / 1073741824 * 10 | floor) / 10)/\((($vm.maxmem // 0) / 1073741824) | floor) GiB" else "-" end)]
			| join("|")' <<<"${planned}"
	} | column -t -s '|' | sed 's/^/    /'
	moved=$(jq -r --argjson vms "${vms}" '($vms | map({key: (.vmid | tostring), value: .node}) | from_entries) as $v
		| [.[] | select($v[.vmid | tostring] and $v[.vmid | tostring] != .host) | .name] | join(" ")' <<<"${planned}")
	if [[ -n ${moved} ]]; then
		log_hint "Migrated VMs: ${moved}."
		[[ $(cfg '.storage.backend') == proxmox-csi ]] &&
			log_hint "Run 'okd-pve storage install' to update their topology labels for Proxmox CSI."
	fi

	local storage first
	storage=$(cfg '.proxmox.vm_storage')
	first=$(jq -r '[.[] | select(.status == "online") | .node] | sort | .[0] // empty' <<<"${hosts}")
	if [[ -n ${first} ]]; then
		echo
		pve_node_storage "${first}" 2>/dev/null | jq -r --arg s "${storage}" '.[] | select(.storage == $s)
			| "    Storage \(.storage): \(((.used // 0) / 1073741824) | floor)/\(((.total // 0) / 1073741824) | floor) GiB used (\(if (.total // 0) > 0 then ((.used / .total * 100) | floor) else 0 end)%)\(if .shared == 1 then ", shared" else "" end)"' || true
	fi
}

cmd_status() {
	(($#)) && die "${EXIT_CONFIG}" "status takes no arguments." "okd-pve status"
	status_cluster
	status_proxmox
}
