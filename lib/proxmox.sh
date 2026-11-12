# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Proxmox VE API helpers used by preflight, destroy, node list and create.
# All are read-only except pve_vm_reset. The API token is passed to curl
# through a config on stdin, never on the command line, so it does not show
# up in the process list.

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

# pve_vm_reset <node> <vmid>: hard reset, like the Reset button (VM.PowerMgmt).
pve_vm_reset() {
	pve_api "/nodes/$1/qemu/$2/status/reset" --data ''
}

pve_pool() {
	pve_api "/pools/$(pve_urlencode "$1")" 2>/dev/null || pve_api "/pools?poolid=$(pve_urlencode "$1")"
}

# pve_task_wait <node> <upid> [timeout-seconds]: wait for a Proxmox task; fails
# with PVE_API_ERROR unless it ends with "OK".
pve_task_wait() {
	local node=$1 upid=$2 timeout=${3:-600} start=${SECONDS} st
	while :; do
		st=$(pve_api "/nodes/${node}/tasks/$(pve_urlencode "${upid}")/status") || return 1
		if [[ $(jq -r '.status' <<<"${st}") == stopped ]]; then
			[[ $(jq -r '.exitstatus // ""' <<<"${st}") == OK ]] && return 0
			PVE_API_ERROR="task failed: $(jq -r '.exitstatus // "unknown"' <<<"${st}")"
			return 1
		fi
		if ((SECONDS - start >= timeout)); then
			PVE_API_ERROR="task still running after ${timeout}s: ${upid}"
			return 1
		fi
		sleep "${OKD_PVE_TASK_POLL:-2}"
	done
}

# pve_iso_size <node> <storage> <file-name>: size in bytes of an ISO on the
# storage; fails when it is not there.
pve_iso_size() {
	pve_api "/nodes/$1/storage/$2/content?content=iso" |
		jq -er --arg v "$2:iso/$3" '[.[] | select(.volid == $v) | .size][0] // empty'
}

# pve_iso_upload <node> <storage> <path> <file-name> <timeout-seconds>: upload
# like the web UI does: multipart POST, Proxmox checks the SHA-256 and moves
# the file into the storage in a task. The only time limit is <timeout>; a
# transfer below 10 KiB/s for 5 minutes is aborted. The token reaches curl on
# stdin, never as an argument.
pve_iso_upload() {
	local node=$1 storage=$2 path=$3 name=$4 timeout=$5 sum out code body upid
	local -a tls=()
	[[ ${PROXMOX_VE_INSECURE:-false} == true ]] && tls=(--insecure)
	sum=$(sha256_file "${path}")
	out=$(
		{ set +x; } 2>/dev/null
		printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" |
			curl -sS --connect-timeout 10 --max-time "${timeout}" --speed-limit 10240 --speed-time 300 \
				-K - "${tls[@]+"${tls[@]}"}" -w '\n%{http_code}' \
				-F content=iso -F checksum-algorithm=sha256 -F "checksum=${sum}" \
				-F "filename=@${path};filename=${name}" \
				"$(pve_api_url "/nodes/${node}/storage/${storage}/upload")" 2>&1
	) || {
		PVE_API_ERROR=$(redact_string "${out}")
		return 1
	}
	code=${out##*$'\n'}
	body=${out%$'\n'*}
	if [[ ${code} != 2* ]]; then
		PVE_API_ERROR="HTTP ${code}: $(jq -r '.message // .errors // empty' <<<"${body}" 2>/dev/null || true)"
		PVE_API_ERROR=$(redact_string "${PVE_API_ERROR}")
		return 1
	fi
	upid=$(jq -r '.data // empty' <<<"${body}" 2>/dev/null)
	[[ -z ${upid} ]] || pve_task_wait "${node}" "${upid}" 900
}

# pve_iso_delete <node> <storage> <file-name>
pve_iso_delete() {
	local upid
	upid=$(pve_api "/nodes/$1/storage/$2/content/$(pve_urlencode "$2:iso/$3")" -X DELETE) || return 1
	upid=$(jq -r 'if type == "string" then . else empty end' <<<"${upid}")
	[[ -z ${upid} ]] || pve_task_wait "$1" "${upid}" 300
}

# pve_vmid_free <vmid>: true when no VM or container uses the VMID. Works
# without audit rights on foreign VMs.
pve_vmid_free() {
	pve_api "/cluster/nextid?vmid=$1" >/dev/null
}
