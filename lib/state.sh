# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Persistent per-cluster state: completed steps (for resuming create) and the
# node slot inventory (which indices of each node group exist as VMs).

[[ -n ${_OKD_PVE_STATE_LOADED:-} ]] && return 0
_OKD_PVE_STATE_LOADED=1

state_init() {
	mkdir -p "${STATE_DIR}/steps" "${STATE_DIR}/hooks"
	chmod 700 "${STATE_DIR}"
}

state_step_done() {
	[[ -n ${STATE_DIR:-} && -f ${STATE_DIR}/steps/$1 ]]
}

state_step_mark() {
	((DRY_RUN)) && return 0
	state_init
	printf '%(%Y-%m-%dT%H:%M:%S%z)T\n' -1 >"${STATE_DIR}/steps/$1"
}

state_step_clear() {
	rm -f "${STATE_DIR}/steps/$1"
}

# state_inventory_get: {"group": [indices...]} or null when no VMs exist yet
# (the node model then derives slots 0..count-1 from cluster.yaml).
state_inventory_get() {
	if [[ -n ${STATE_DIR:-} && -f ${STATE_DIR}/inventory.json ]]; then
		jq -c . "${STATE_DIR}/inventory.json"
	else
		echo null
	fi
}

state_inventory_set() {
	((DRY_RUN)) && return 0
	state_init
	jq -c . <<<"$1" >"${STATE_DIR}/inventory.json.tmp"
	mv "${STATE_DIR}/inventory.json.tmp" "${STATE_DIR}/inventory.json"
	nodes_invalidate
}

# state_inventory_freeze: persist the inventory derived from cluster.yaml.
state_inventory_freeze() {
	[[ -f ${STATE_DIR}/inventory.json ]] && return 0
	state_inventory_set "$(jq_lib -c 'include "nodes"; default_inventory' "${CONFIG_JSON}")"
}

# state_inventory_matches_config: counts in cluster.yaml equal the inventory.
state_inventory_matches_config() {
	local inv
	inv=$(state_inventory_get)
	[[ ${inv} == null ]] && return 0
	jq -e --argjson inv "${inv}" \
		'[.node_groups[] | (.count // 0) == (($inv[.name] // []) | length)] | all' \
		"${CONFIG_JSON}" >/dev/null
}

# state_hash_inputs <files...>: sha256 over files (sorted by name).
state_hash_inputs() {
	local f
	for f in "$@"; do
		[[ -f ${f} ]] || continue
		printf '%s\n' "${f##*/}"
		cat "${f}"
	done | sha256_stdin
}

sha256_stdin() {
	if have_cmd sha256sum; then
		sha256sum | awk '{ print $1 }'
	else
		shasum -a 256 | awk '{ print $1 }'
	fi
}

sha256_file() {
	sha256_stdin <"$1"
}

# state_hook_result <name> <result> <seconds>
state_hook_result() {
	((DRY_RUN)) && return 0
	state_init
	printf '%s %s %(%Y-%m-%dT%H:%M:%S%z)T\n' "$2" "$3" -1 >"${STATE_DIR}/hooks/$1"
}

state_hook_last() {
	[[ ! -f ${STATE_DIR}/hooks/$1 ]] || cat "${STATE_DIR}/hooks/$1"
}

state_wipe() {
	rm -rf "${STATE_DIR}"
}
