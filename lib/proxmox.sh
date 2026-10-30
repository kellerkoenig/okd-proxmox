# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Read-only Proxmox VE API helpers used by preflight, destroy and node list.
# The API token is passed to curl through a config on stdin, never on the
# command line, so it does not show up in the process list.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_PROXMOX_LOADED:-} ]] && return 0
_OKD_PVE_PROXMOX_LOADED=1

PVE_API_ERROR=''

pve_api_url() {
	local base=${PROXMOX_VE_ENDPOINT%/}
	base=${base%/api2/json}
	printf '%s/api2/json%s' "${base}" "$1"
}

# pve_api <path> [curl-args...]: GET a path, print the "data" member.
# Returns 1 on HTTP or transport errors (message in PVE_API_ERROR).
pve_api() {
	local path=$1 out code body
	shift
	local -a tls=()
	[[ ${PROXMOX_VE_INSECURE:-false} == true ]] && tls=(--insecure)
	out=$(
		{ set +x; } 2>/dev/null
		printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" |
			curl -sS --connect-timeout 10 --max-time 60 -K - "${tls[@]+"${tls[@]}"}" \
				-w '\n%{http_code}' "$@" "$(pve_api_url "${path}")" 2>&1
	) || {
		PVE_API_ERROR=$(redact_string "${out}")
		log_debug "GET ${path}: ${PVE_API_ERROR}"
		return 1
	}
	code=${out##*$'\n'}
	body=${out%$'\n'*}
	if [[ ${code} != 2* ]]; then
		PVE_API_ERROR="HTTP ${code}: $(jq -r '.message // .errors // empty' <<<"${body}" 2>/dev/null || true)"
		PVE_API_ERROR=$(redact_string "${PVE_API_ERROR}")
		log_debug "GET ${path}: ${PVE_API_ERROR}"
		return 1
	fi
	jq -c '.data' <<<"${body}"
}

pve_version() {
	pve_api /version | jq -r '.version // empty'
}

# pve_permissions <path>: effective privileges of the token on a path, one
# privilege per line.
pve_permissions() {
	pve_api "/access/permissions?path=$(pve_urlencode "$1")" | jq -r --arg p "$1" '.[$p] // {} | keys[]'
}

pve_urlencode() {
	jq -rn --arg v "$1" '$v | @uri'
}

pve_nodes() {
	pve_api /nodes
}

pve_node_status() {
	pve_api "/nodes/$1/status"
}

pve_node_storage() {
	pve_api "/nodes/$1/storage"
}

pve_node_networks() {
	pve_api "/nodes/$1/network"
}

pve_sdn_vnets() {
	pve_api /cluster/sdn/vnets
}

pve_cluster_vms() {
	pve_api '/cluster/resources?type=vm'
}

pve_vm_config() {
	pve_api "/nodes/$1/qemu/$2/config"
}

pve_pool() {
	pve_api "/pools/$(pve_urlencode "$1")" 2>/dev/null || pve_api "/pools?poolid=$(pve_urlencode "$1")"
}

# pve_vmid_free <vmid>: true when no VM or container uses the VMID. Works
# without audit rights on foreign VMs.
pve_vmid_free() {
	pve_api "/cluster/nextid?vmid=$1" >/dev/null
}
