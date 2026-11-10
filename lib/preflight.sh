# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Preflight checks. Every check prints PASS/WARN/FAIL with a concrete hint.
# Nothing in here changes anything, locally or on Proxmox.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_PREFLIGHT_LOADED:-} ]] && return 0
_OKD_PVE_PREFLIGHT_LOADED=1

PF_PASS=0
PF_WARN=0
PF_FAIL=0
PF_PVE_OK=0
# Names of this cluster's VMs that already exist (resumed create).
declare -gA PF_OWNED_VMIDS=()
pf_capacity_fail=()

# Privileges the installer token needs, per ACL path type. PVE 8 and 9 use
# the same names for everything we need (VM.Monitor, removed in 9, is not used).
PF_PRIVS_POOL=(VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType
	VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt Pool.Audit)
PF_PRIVS_VM_STORAGE=(Datastore.AllocateSpace Datastore.Audit)
# Datastore.Allocate: Proxmox requires it to delete the ISO again (detach/destroy).
PF_PRIVS_ISO_STORAGE=(Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit)
PF_PRIVS_NODE=(Sys.Audit)
PF_PRIVS_BRIDGE=(SDN.Use)
# Proxmox checks the HA API (resources, rules) on "/" only.
PF_PRIVS_HA=(Sys.Audit Sys.Console)

pf() {
	local status=$1 msg=$2 hint=${3:-}
	_log_to_file "PREFLIGHT-${status}" "${msg}${hint:+ -- ${hint}}"
	local color=''
	case ${status} in
	PASS) ((++PF_PASS)) && color=${C_GREEN} ;;
	WARN) ((++PF_WARN)) && color=${C_YELLOW} ;;
	FAIL) ((++PF_FAIL)) && color=${C_RED} ;;
	INFO) color=${C_DIM} ;;
	esac
	printf '    %s[%s]%s %s\n' "${color}" "${status}" "${C_RESET}" "$(redact_string "${msg}")"
	if [[ -n ${hint} && ${status} != PASS ]]; then
		printf '           %s-> %s%s\n' "${C_DIM}" "$(redact_string "${hint}")" "${C_RESET}"
	fi
}

# preflight_run: run all checks; returns 0 when there is no FAIL.
preflight_run() {
	PF_PASS=0 PF_WARN=0 PF_FAIL=0
	log_step "Preflight: configuration"
	pf_config
	log_step "Preflight: local workstation"
	pf_local
	log_step "Preflight: Proxmox VE"
	pf_proxmox
	if ((PF_PVE_OK)); then
		log_step "Preflight: capacity"
		pf_capacity
	fi
	log_step "Preflight: network, DNS and time"
	pf_network
	if mirrors_enabled; then
		log_step "Preflight: registry mirrors"
		pf_mirrors
	fi
	printf '\n'
	local summary="Preflight: ${PF_PASS} passed, ${PF_WARN} warnings, ${PF_FAIL} failed"
	if ((PF_FAIL)); then
		log_error "${summary}"
		return 1
	fi
	if ((PF_WARN)); then
		log_warn "${summary}"
	else
		log_ok "${summary}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

pf_config() {
	pf PASS "cluster.yaml and install-config.yaml are valid (cluster ${CLUSTER_NAME}.${BASE_DOMAIN}, OKD $(cfg '.okd.version'))"
	local w
	while IFS= read -r w; do
		[[ -n ${w} ]] && pf WARN "${w}"
	done < <(config_warnings)

	local masters workers infra_nodes worker_role
	masters=$(nodes_query '[.[] | select(.agent_role == "master")] | length')
	workers=$(nodes_query '[.[] | select(.agent_role == "worker")] | length')
	infra_nodes=$(nodes_query '[.[] | select(.infra)] | length')
	worker_role=$(nodes_query '[.[] | select(.roles | index("worker"))] | length')
	if ((masters == 1)); then
		if ((workers > 0)) && ! state_step_done vms; then
			pf FAIL "Single-node cluster with ${workers} additional node(s) at install time" \
				"Set the count of all non-master groups to 0; add workers after installation with 'okd-pve node add'."
		else
			pf PASS "Topology: single-node cluster (platform none)"
		fi
	else
		pf PASS "Topology: ${masters} control-plane, ${workers} other node(s) (${infra_nodes} with infra role)"
	fi
	if ((infra_nodes > 0 && worker_role < 2)); then
		pf FAIL "Infra role used with only ${worker_role} worker node(s)" \
			"Use at least 2 worker nodes so applications have somewhere to run besides infra."
	fi
	if ((infra_nodes == 1)); then
		pf WARN "Only one infra node: ingress and monitoring have no redundancy" "Use at least 2 (better 3) infra nodes."
	fi

	local ps_src
	ps_src=$(pull_secret_source)
	if pull_secret_value | jq -e '.auths | type == "object"' >/dev/null 2>&1; then
		pf PASS "Pull secret is valid JSON (source: ${ps_src})"
		if [[ ${ps_src} == "built-in OKD placeholder" ]] && grep -q redhat <<<"$(cfg '.hooks.env.OKD_PVE_CATALOG_PROFILE')"; then
			pf WARN "Catalog profile 'redhat' with the placeholder pull secret" \
				"Images from registry.redhat.io need a real pull secret; set install.pull_secret_file."
		fi
	else
		pf FAIL "Pull secret from ${ps_src} is not valid JSON with an 'auths' object" \
			"Download it from https://console.redhat.com/openshift/install/pull-secret or remove it to use the OKD placeholder."
	fi

	local key
	key=$(ssh_key_value 2>/dev/null || true)
	if [[ ${key} =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com)\  ]]; then
		pf PASS "SSH public key found (${key%% *})"
	else
		pf FAIL "No SSH public key found" \
			"Set sshKey in install-config.yaml or install.ssh_public_key_file in cluster.yaml (needed to debug nodes)."
	fi

	pf_preboot_render

	local sc backend
	sc=$(monitoring_storage_class)
	backend=$(cfg '.storage.backend')
	if [[ -z ${sc} ]]; then
		pf INFO "No StorageClass for monitoring configured; Prometheus/Alertmanager use emptyDir"
	elif [[ ${backend} != none && (${sc} == "$(cfg '.storage.storage_class')" || ${sc} == "$(cfg '.storage.storage_class')-retain") ]]; then
		pf PASS "Monitoring StorageClass ${sc} is created by storage backend ${backend}"
	elif hooks_provide_storage_class "${sc}"; then
		pf PASS "Monitoring StorageClass ${sc} is defined in the hook manifests"
	else
		pf WARN "Monitoring StorageClass ${sc} is neither created by storage.backend nor found in hook manifests" \
			"Set storage.backend, add a StorageClass manifest to the hooks, or make sure a hook script creates it."
	fi
}

config_warnings() {
	jq_lib -r -n --arg cluster "${CLUSTER_NAME}" --argjson inv "$(state_inventory_get)" \
		--slurpfile c "${CONFIG_JSON}" --slurpfile ic "${INSTALL_CONFIG_JSON}" \
		'include "validate"; $c[0] | validate($cluster; $inv; $ic[0]) | .warnings[]'
}

pf_preboot_render() {
	local bu
	if ! bu=$(tool_check butane); then
		pf WARN "Pre-Boot manifests not test-rendered: butane is not installed yet" \
			"create downloads butane; or install it now and re-run preflight."
		return
	fi
	BUTANE=${bu%%$'\t'*}
	local out err
	out=$(mktemp -d "${OKD_PVE_TMP}/preboot.XXXXXX")
	if err=$(manifests_render "${out}" 2>&1); then
		pf PASS "Pre-Boot manifests render cleanly ($(find "${out}" -type f | wc -l | tr -d ' ') files)"
	else
		pf FAIL "Pre-Boot manifests do not render: ${err##*$'\n'}" "Check templates/preboot and ${PREBOOT_USER_DIR}."
	fi
}

# ---------------------------------------------------------------------------
# Local workstation
# ---------------------------------------------------------------------------

pf_local() {
	if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
		pf PASS "bash ${BASH_VERSION%%(*}"
	else
		pf FAIL "bash ${BASH_VERSION} is too old" "Install bash 4.4 or newer (macOS: brew install bash)."
	fi
	pf PASS "jq $(jq --version 2>&1 | sed 's/^jq-//'), yq $(yq --version 2>&1 | awk '{ print $NF }')"
	local c
	for c in curl awk sed tar; do
		have_cmd "${c}" && continue
		pf FAIL "${c} is not installed" "Install ${c} with your package manager."
	done
	local nm engine
	if nm=$(tool_check nmstatectl); then
		pf PASS "nmstatectl ${nm#*$'\t'} (${nm%%$'\t'*}; openshift-install validates the static network config with it)"
	elif engine=$(container_engine); then
		pf WARN "nmstatectl is not installed" \
			"create extracts it from the CentOS Stream 9 nmstate package with ${engine} into ${BIN_DIR} (or: dnf install nmstate)."
	else
		pf FAIL "nmstatectl is not installed (openshift-install needs it for static IP configuration)" \
			"Install the nmstate package (dnf install nmstate), or podman/docker so okd-pve can extract it."
	fi
	for c in getent ping timeout; do
		have_cmd "${c}" || pf WARN "${c} is not installed; some network checks are skipped" "Install ${c}."
	done

	local name found
	for name in openshift-install oc tofu butane; do
		if found=$(tool_check "${name}"); then
			pf PASS "${name} ${found#*$'\t'} (${found%%$'\t'*})"
		else
			pf WARN "${name} not found in a suitable version" \
				"create will offer to download it into ${BIN_DIR} (or install it into PATH)."
		fi
	done
	if ! tool_check tofu >/dev/null && ! have_cmd unzip; then
		pf FAIL "unzip is required to download OpenTofu" "Install unzip or install tofu yourself."
	fi

	local free need=$((5 * 1024 * 1024 * 1024))
	free=$(free_bytes "${CLUSTER_DIR}")
	if ((free >= need)); then
		pf PASS "Cluster directory: $(human_gib "${free}") free"
	else
		pf FAIL "Cluster directory: only $(human_gib "${free}") free, need 5 GiB (agent ISO ~1 GiB, tools, logs)" \
			"Free up space or use --dir on a larger filesystem."
	fi
	local tmp=${TMPDIR:-/tmp} tmp_cfg
	tmp_cfg=$(cfg '.proxmox.tmp_dir')
	[[ -n ${tmp_cfg} ]] && tmp=${tmp_cfg}
	free=$(free_bytes "${tmp}")
	if ((free >= 2 * 1024 * 1024 * 1024)); then
		pf PASS "Upload buffer ${tmp}: $(human_gib "${free}") free"
	else
		pf FAIL "Upload buffer ${tmp}: only $(human_gib "${free}") free; the ~1 GiB agent ISO is buffered there during upload" \
			"Set proxmox.tmp_dir in cluster.yaml (passed to the provider as tmp_dir) to a directory with >= 2 GiB."
	fi
	local cache=${XDG_CACHE_HOME:-${HOME}/.cache}
	free=$(free_bytes "${cache}")
	if ((free < 2 * 1024 * 1024 * 1024)); then
		pf WARN "${cache}: only $(human_gib "${free}") free; openshift-install caches the ~1 GiB base ISO there" \
			"Free up space or set XDG_CACHE_HOME."
	fi
}

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------

pf_proxmox() {
	PF_PVE_OK=0
	local ver='' vf=${OKD_PVE_TMP}/pve-version.json
	# Not in a command substitution: PVE_API_ERROR must survive for the message.
	if pve_api /version >"${vf}"; then
		ver=$(jq -r '.version // empty' "${vf}")
	fi
	if [[ -z ${ver} ]]; then
		pf FAIL "Proxmox API ${PROXMOX_VE_ENDPOINT} not usable: ${PVE_API_ERROR:-no version in the answer}" \
			"Check PROXMOX_VE_ENDPOINT, the token (user@realm!id=secret), PROXMOX_VE_INSECURE for self-signed certs, and the firewall."
		return
	fi
	PF_PVE_OK=1
	pf PASS "API reachable, token valid (Proxmox VE ${ver})"
	if version_ge "${ver}" "${PVE_MIN_VERSION}"; then
		pf PASS "Proxmox VE ${ver} is supported"
	else
		pf WARN "Proxmox VE ${ver} is end of life and not tested" "Upgrade to Proxmox VE 8 or 9."
	fi

	local pool hosts
	pool=$(pool_name)
	mapfile -t hosts < <(nodes_query '[.[].host] | unique | .[]')

	pf_privileges "${pool}" "${hosts[@]}"

	local pve_nodes
	pve_nodes=$(pve_nodes) || pve_nodes='[]'
	local h status
	for h in "${hosts[@]}"; do
		status=$(jq -r --arg n "${h}" '.[] | select(.node == $n) | .status' <<<"${pve_nodes}")
		case ${status} in
		online) pf PASS "Node ${h} is online" ;;
		'') pf FAIL "Node ${h} does not exist (or the token cannot see it)" \
			"Check proxmox.nodes; known nodes: $(jq -r '[.[].node] | join(", ")' <<<"${pve_nodes}")" ;;
		*) pf FAIL "Node ${h} is ${status}" "Bring the node online or remove it from proxmox.nodes." ;;
		esac
	done

	if pve_pool "${pool}" >/dev/null; then
		pf PASS "Resource pool ${pool} exists"
	else
		pf FAIL "Resource pool ${pool} does not exist or is not visible" \
			"Create it: pveum pool add ${pool} (see docs/proxmox-permissions.md)."
	fi

	# VMIDs first: the space check skips VMs that already exist.
	pf_vmids "${pool}"
	pf_storage "${hosts[@]}"
	pf_bridge "${hosts[@]}"
	pf_cpu_model "${hosts[@]}"
	pf_ha "${hosts[@]}"
	pf_macs
}

pf_privileges() {
	local pool=$1 h path missing
	shift
	local -a checks=("/pool/${pool}:${PF_PRIVS_POOL[*]}")
	local s
	for s in $(storages_vm) $(cfg '.proxmox.efi_storage'); do
		checks+=("/storage/${s}:${PF_PRIVS_VM_STORAGE[*]}")
	done
	checks+=("/storage/$(cfg '.proxmox.iso_storage'):${PF_PRIVS_ISO_STORAGE[*]}")
	for h in "$@"; do
		checks+=("/nodes/${h}:${PF_PRIVS_NODE[*]}")
	done
	checks+=("/sdn/zones/localnetwork/$(cfg '.proxmox.bridge'):${PF_PRIVS_BRIDGE[*]}")
	[[ $(cfg '.proxmox.ha.enabled') == true ]] && checks+=("/:${PF_PRIVS_HA[*]}")

	local entry have
	for entry in $(printf '%s\n' "${checks[@]}" | sort -u | tr ' ' ','); do
		path=${entry%%:*}
		if ! have=$(pve_permissions "${path}"); then
			pf WARN "Cannot read permissions for ${path}: ${PVE_API_ERROR}"
			continue
		fi
		missing=()
		local p wanted=()
		IFS=, read -r -a wanted <<<"${entry#*:}"
		for p in "${wanted[@]}"; do
			grep -qx "${p}" <<<"${have}" || missing+=("${p}")
		done
		if ((${#missing[@]} == 0)); then
			pf PASS "Privileges on ${path}"
		elif [[ ${path} == / ]]; then
			pf FAIL "Missing privileges on / for proxmox.ha: ${missing[*]}" \
				"pveum acl modify / --tokens '<token>' --roles <role with Sys.Audit,Sys.Console> --propagate 0, or set proxmox.ha.enabled: false."
		elif [[ ${path} == /sdn/* ]]; then
			pf WARN "Missing ${missing[*]} on ${path}" \
				"Needed to attach VMs to bridge $(cfg '.proxmox.bridge'): pveum acl modify ${path} --tokens '<token>' --roles PVESDNUser"
		else
			pf FAIL "Missing privileges on ${path}: ${missing[*]}" \
				"Grant them to the token (with privilege separation the token needs its own ACL). See docs/proxmox-permissions.md."
		fi
	done
}

# storages_vm: every storage that receives VM disks.
storages_vm() {
	{
		cfg '.proxmox.vm_storage'
		nodes_query '.[].data_disks[].storage'
	} | sort -u
}

pf_storage() {
	local h s info iso_storage
	iso_storage=$(cfg '.proxmox.iso_storage')
	for h in "$@"; do
		if ! info=$(pve_node_storage "${h}"); then
			pf FAIL "Cannot list storage on ${h}: ${PVE_API_ERROR}" "Grant Datastore.Audit / Sys.Audit."
			continue
		fi
		for s in $(storages_vm) $(cfg '.proxmox.efi_storage'); do
			pf_storage_one "${h}" "${s}" images "${info}"
		done
		pf_storage_one "${h}" "${iso_storage}" iso "${info}"
	done
	pf_storage_space "$@"
}

pf_storage_one() {
	local h=$1 s=$2 content=$3 info=$4 row
	row=$(jq -c --arg s "${s}" '.[] | select(.storage == $s)' <<<"${info}")
	if [[ -z ${row} ]]; then
		pf FAIL "Storage ${s} does not exist on ${h}" "Check the storage name or restrict it to the right nodes."
		return
	fi
	if [[ $(jq -r '.active // 0' <<<"${row}") != 1 || $(jq -r '.enabled // 1' <<<"${row}") == 0 ]]; then
		pf FAIL "Storage ${s} on ${h} is not active" "Enable/activate the storage in Datacenter -> Storage."
		return
	fi
	if jq -e --arg c "${content}" '.content | split(",") | index($c)' <<<"${row}" >/dev/null; then
		pf PASS "Storage ${s} on ${h} allows ${content}"
	else
		pf FAIL "Storage ${s} on ${h} does not allow content type '${content}' (has: $(jq -r .content <<<"${row}"))" \
			"Add '${content}' to the storage content types."
	fi
}

# pf_storage_space: disks per storage (per node unless shared) vs. available.
# VMs of this cluster that already exist (resumed create) need no new space.
pf_storage_space() {
	local h s info need avail shared type key owned
	local -A need_by=() avail_by=() type_by=()
	owned=$(printf '%s\n' "${!PF_OWNED_VMIDS[@]}" | jq -Rsc '[split("\n")[] | select(. != "") | tonumber]')
	if [[ $(nodes_query --argjson o "${owned}" '[.[] | select(.vmid as $v | $o | index($v) | not)] | length') == 0 ]]; then
		pf INFO "All VMs of this cluster already exist; skipping the storage space check"
		return 0
	fi
	for h in "$@"; do
		info=$(pve_node_storage "${h}") || continue
		while IFS=$'\t' read -r s need; do
			shared=$(jq -r --arg s "${s}" '.[] | select(.storage == $s) | .shared // 0' <<<"${info}")
			avail=$(jq -r --arg s "${s}" '.[] | select(.storage == $s) | .avail // 0' <<<"${info}")
			type=$(jq -r --arg s "${s}" '.[] | select(.storage == $s) | .type // ""' <<<"${info}")
			[[ -n ${avail} ]] || continue
			if [[ ${shared} == 1 ]]; then key="${s} (shared)"; else key="${s} on ${h}"; fi
			need_by[${key}]=$((${need_by[${key}]:-0} + need))
			avail_by[${key}]=${avail}
			type_by[${key}]=${type}
		done < <(nodes_query --arg h "${h}" --arg vs "$(cfg '.proxmox.vm_storage')" --argjson o "${owned}" '
			[.[] | select(.host == $h and (.vmid as $v | $o | index($v) | not))
				| {s: $vs, g: .disk_gib}, (.data_disks[] | {s: .storage, g: .size_gib})]
			| group_by(.s)[] | "\(.[0].s)\t\(map(.g) | add * 1073741824 | floor)"')
	done
	for key in "${!need_by[@]}"; do
		need=${need_by[${key}]}
		avail=${avail_by[${key}]}
		if ((need <= avail)); then
			pf PASS "Space on ${key}: need $(human_gib "${need}"), $(human_gib "${avail}") available"
		elif [[ ${type_by[${key}]} =~ ^(lvmthin|zfspool|rbd|cephfs|btrfs)$ ]]; then
			pf WARN "Space on ${key}: disks total $(human_gib "${need}") but only $(human_gib "${avail}") available (thin-provisioned ${type_by[${key}]})" \
				"Thin provisioning allows this, but watch the pool; a full pool pauses all VMs on it."
		else
			pf FAIL "Space on ${key}: need $(human_gib "${need}"), only $(human_gib "${avail}") available" \
				"Use another storage, smaller disks or free up space."
		fi
	done
}

pf_bridge() {
	local h bridge nets vnets
	bridge=$(cfg '.proxmox.bridge')
	vnets=$(pve_sdn_vnets 2>/dev/null || echo '[]')
	for h in "$@"; do
		if ! nets=$(pve_node_networks "${h}"); then
			pf WARN "Cannot list networks on ${h}: ${PVE_API_ERROR}" "Grant Sys.Audit on /nodes/${h}."
			continue
		fi
		if jq -e --arg b "${bridge}" '.[] | select(.iface == $b and (.type == "bridge" or .type == "OVSBridge"))' <<<"${nets}" >/dev/null; then
			pf PASS "Bridge ${bridge} exists on ${h}"
		elif jq -e --arg b "${bridge}" '.[]? | select(.vnet == $b)' <<<"${vnets}" >/dev/null; then
			pf PASS "SDN VNet ${bridge} exists (node ${h})"
		else
			pf FAIL "Bridge ${bridge} not found on ${h}" "Check proxmox.bridge; available: $(jq -r '[.[] | select(.type | test("ridge")) | .iface] | join(", ")' <<<"${nets}")"
		fi
	done
}

# SCOS 9 needs x86-64-v2, SCOS 10 (CentOS Stream 10) needs x86-64-v3.
pf_cpu_model() {
	local type h flags missing f
	type=$(cfg '.proxmox.cpu_type')
	case ${type} in
	kvm64 | qemu64 | kvm32 | qemu32)
		pf FAIL "CPU type ${type} lacks the instruction set SCOS needs (x86-64-v2 or newer)" \
			"Set proxmox.cpu_type to host or x86-64-v3."
		return
		;;
	x86-64-v2 | x86-64-v2-AES)
		pf WARN "CPU type ${type}: SCOS based on CentOS Stream 10 requires x86-64-v3" \
			"Use host or x86-64-v3 unless your hosts lack AVX2."
		;;
	esac
	[[ ${type} == host || ${type} == x86-64-v3 || ${type} == x86-64-v4 ]] || return 0
	for h in "$@"; do
		flags=$(pve_node_status "${h}" 2>/dev/null | jq -r '.cpuinfo.flags // empty') || true
		[[ -n ${flags} ]] || continue
		missing=()
		for f in avx2 bmi2 fma movbe; do
			[[ " ${flags} " == *" ${f} "* ]] || missing+=("${f}")
		done
		if ((${#missing[@]})); then
			pf FAIL "Host ${h} CPU lacks x86-64-v3 features (${missing[*]})" \
				"SCOS 10 does not boot there; use other hosts or an older OKD release."
		else
			pf PASS "Host ${h} CPU supports x86-64-v3"
		fi
	done
}

# pf_ha: what the HA manager needs to restart a VM on another node.
pf_ha() {
	[[ $(cfg '.proxmox.ha.enabled') == true ]] || return 0
	local info s shared count
	info=$(pve_node_storage "$1" 2>/dev/null) || info='[]'
	for s in $(storages_vm) $(cfg '.proxmox.efi_storage'); do
		shared=$(jq -r --arg s "${s}" '.[] | select(.storage == $s) | .shared // 0' <<<"${info}")
		[[ -n ${shared} ]] || continue
		if [[ ${shared} == 1 ]]; then
			pf PASS "HA: storage ${s} is shared"
		else
			pf FAIL "HA: storage ${s} is local to each node; HA cannot restart VMs elsewhere" \
				"Use shared VM storage or set proxmox.ha.enabled: false."
		fi
	done
	if [[ $(cfg '.proxmox.cpu_type') == host ]]; then
		pf WARN "HA: cpu_type host; live migration fails between hosts with different CPUs" \
			"Set proxmox.cpu_type to a named model such as x86-64-v3."
	fi
	count=$(pve_nodes 2>/dev/null | jq 'length' 2>/dev/null) || count=0
	if ((count == 2)); then
		pf WARN "HA: two-node Proxmox cluster; it keeps quorum after a node failure only with a QDevice" \
			"Check 'pvecm status' on a node (Qdevice listed); without quorum HA restarts nothing."
	fi
}

pf_vmids() {
	local pool=$1 vms vmid name used=() owned=0
	vms=$(pve_cluster_vms 2>/dev/null || echo '[]')
	PF_OWNED_VMIDS=()
	while IFS=$'\t' read -r vmid name; do
		if pve_vmid_free "${vmid}"; then
			continue
		fi
		if jq -e --argjson id "${vmid}" --arg n "${name}" --arg p "${pool}" \
			'.[] | select(.vmid == $id and .name == $n and (.pool // "") == $p)' <<<"${vms}" >/dev/null; then
			PF_OWNED_VMIDS[${vmid}]=${name}
			((++owned))
		else
			used+=("${vmid}")
		fi
	done < <(nodes_query '.[] | "\(.vmid)\t\(.name)"')
	if ((${#used[@]})); then
		pf FAIL "VMIDs already in use: ${used[*]}" "Choose another proxmox.vmid_start or free the VMIDs."
	else
		local note=''
		((owned)) && note=" (${owned} already belong to this cluster)"
		pf PASS "All $(nodes_query 'length') VMIDs are free${note}"
	fi
}

pf_macs() {
	local prefix vms ours conflicts=() row node vmid cfgjson
	prefix=$(cfg '.proxmox.mac_prefix' | tr '[:upper:]' '[:lower:]')
	vms=$(pve_cluster_vms 2>/dev/null || echo '[]')
	ours=$(nodes_query '[.[].vmid]')
	while IFS=$'\t' read -r node vmid; do
		cfgjson=$(pve_vm_config "${node}" "${vmid}" 2>/dev/null) || continue
		while IFS= read -r row; do
			conflicts+=("${row} (VM ${vmid})")
		done < <(jq -r --arg p "${prefix}" --argjson macs "$(nodes_query '[.[].mac]')" '
			to_entries[] | select(.key | test("^net[0-9]+$")) | .value
			| capture("=(?<m>[0-9A-Fa-f:]{17})") | .m | ascii_downcase
			| select(. as $m | $macs | index($m))' <<<"${cfgjson}")
	done < <(jq -r --argjson ours "${ours}" '.[] | select(.type == "qemu") | select(.vmid as $v | $ours | index($v) | not) | "\(.node)\t\(.vmid)"' <<<"${vms}")
	if ((${#conflicts[@]})); then
		pf FAIL "MAC addresses already used by other VMs: ${conflicts[*]}" "Change proxmox.mac_prefix or proxmox.vmid_start."
	else
		pf PASS "No visible VM uses one of the generated MAC addresses (prefix ${prefix})"
	fi
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

pf_capacity() {
	local vms reserve h status threads memtotal ex_cpu ex_mem pl_cpu pl_mem free ratio
	vms=$(pve_cluster_vms 2>/dev/null || echo '[]')
	reserve=$(($(cfg '.proxmox.host_memory_reserve_gib') * 1073741824))
	local ours
	ours=$(nodes_query '[.[].vmid]')
	local -a rows=()
	local t_threads=0 t_ex_cpu=0 t_pl_cpu=0 t_mem=0 t_ex_mem=0 t_pl_mem=0 fail=0 warn_ratio=''
	while IFS= read -r h; do
		status=$(pve_node_status "${h}") || {
			pf WARN "Cannot read status of ${h}: ${PVE_API_ERROR}"
			continue
		}
		threads=$(jq -r '.cpuinfo.cpus // 0' <<<"${status}")
		memtotal=$(jq -r '.memory.total // 0' <<<"${status}")
		read -r ex_cpu ex_mem < <(jq -r --arg h "${h}" --argjson ours "${ours}" '
			[.[] | select(.node == $h and .status == "running" and (.vmid as $v | $ours | index($v) | not))]
			| "\(map(.maxcpu // 0) | add // 0) \(map(.maxmem // 0) | add // 0)"' <<<"${vms}")
		read -r pl_cpu pl_mem < <(nodes_query --arg h "${h}" \
			'[.[] | select(.host == $h)] | "\(map(.cpu) | add // 0) \(map(.memory_mib * 1048576) | add // 0)"')
		free=$((memtotal - reserve - ex_mem - pl_mem))
		ratio=$(awk -v a="$((ex_cpu + pl_cpu))" -v b="${threads}" 'BEGIN { printf "%.1f", (b > 0 ? a / b : 0) }')
		rows+=("${h}|${threads}|${ex_cpu}|${pl_cpu}|${ratio}:1|$(human_gib "${memtotal}")|$(human_gib "${ex_mem}")|$(human_gib "${pl_mem}")|$(human_gib "${free}")")
		((t_threads += threads, t_ex_cpu += ex_cpu, t_pl_cpu += pl_cpu, t_mem += memtotal, t_ex_mem += ex_mem, t_pl_mem += pl_mem)) || true
		if ((free < 0)); then
			pf_capacity_fail+=("${h}: RAM overcommitted by $(human_gib $((-free))) (incl. $(cfg '.proxmox.host_memory_reserve_gib') GiB host reserve)")
			fail=1
		fi
		if awk -v r="${ratio}" 'BEGIN { exit !(r > 1) }'; then
			warn_ratio+="${h}=${ratio}:1 "
		fi
	done < <(nodes_query '[.[].host] | unique | .[]')

	rows+=("TOTAL|${t_threads}|${t_ex_cpu}|${t_pl_cpu}|-|$(human_gib "${t_mem}")|$(human_gib "${t_ex_mem}")|$(human_gib "${t_pl_mem}")|-")
	{
		printf 'HOST|THREADS|vCPU RUNNING|vCPU NEW|CPU RATIO|RAM TOTAL|RAM RUNNING|RAM NEW|RAM FREE AFTER\n'
		printf '%s\n' "${rows[@]}"
	} | column -t -s '|' | sed 's/^/      /' | tee >(redact_stream --log "${LOG_FILE}" >/dev/null)

	if ((fail)); then
		local f
		for f in "${pf_capacity_fail[@]}"; do
			pf FAIL "${f}" "Without ballooning Proxmox swaps or refuses to start VMs. Reduce memory_gib, add hosts or stop other VMs."
		done
		pf_capacity_fail=()
	else
		pf PASS "RAM fits on every host (host reserve $(cfg '.proxmox.host_memory_reserve_gib') GiB)"
	fi
	if [[ -z ${warn_ratio} ]]; then
		pf PASS "No CPU overcommit"
	elif awk -v r="$(tr ' ' '\n' <<<"${warn_ratio}" | sed -n 's/.*=\([0-9.]*\):1/\1/p' | sort -rn | head -n1)" 'BEGIN { exit !(r > 4) }'; then
		pf WARN "CPU overcommit above 4:1: ${warn_ratio}" \
			"This is high; expect CPU steal under load. Typical OKD nodes run well below their vCPU allocation, but above 4:1 control-plane latency suffers."
	else
		pf WARN "CPU overcommit: ${warn_ratio}" "A moderate ratio is normal for OKD; nodes rarely use their full vCPU allocation."
	fi
}

# ---------------------------------------------------------------------------
# Network, DNS, time
# ---------------------------------------------------------------------------

# resolve_ipv4 <name>: IPv4 addresses via the local resolver.
resolve_ipv4() {
	if have_cmd getent; then
		getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u
	elif have_cmd dig; then
		dig +short A "$1" | grep -E '^[0-9.]+$' | sort -u
	fi
}

# resolve_ipv4_at <server> <name>
resolve_ipv4_at() {
	dig +short +time=2 +tries=1 A "@$1" "$2" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u
}

host_answers() {
	local ip=$1
	if have_cmd ping; then
		ping -c 1 -W 1 "${ip}" >/dev/null 2>&1 && return 0
	fi
	tcp_open "${ip}" 443 || tcp_open "${ip}" 6443 || tcp_open "${ip}" 22
}

tcp_open() {
	have_cmd timeout || return 1
	timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# ntp_query <server>: print the server's transmit time (unix seconds).
ntp_query() {
	local f
	f=$(mktemp "${OKD_PVE_TMP}/ntp.XXXXXX")
	timeout 4 bash -c '
		exec 3<>"/dev/udp/$1/123" || exit 1
		printf "\x1b%047d" 0 | tr 0 "\000" >&3
		head -c 48 <&3 >"$2"' _ "$1" "${f}" 2>/dev/null || {
		rm -f "${f}"
		return 1
	}
	if [[ $(wc -c <"${f}") -lt 48 ]]; then
		rm -f "${f}"
		return 1
	fi
	od -An -tu1 -j40 -N4 "${f}" | awk '{ printf "%d\n", ($1 * 16777216 + $2 * 65536 + $3 * 256 + $4) - 2208988800 }'
	rm -f "${f}"
}

pf_network() {
	local platform api_vip ingress_vip expect_api expect_apps
	platform=$(platform_type)
	if [[ ${platform} == none ]]; then
		expect_api=$(nodes_query '.[] | select(.agent_role == "master") | .ip')
		expect_apps=${expect_api}
	else
		api_vip=$(ic '.platform.baremetal.apiVIPs[0]')
		ingress_vip=$(ic '.platform.baremetal.ingressVIPs[0]')
		expect_api=${api_vip}
		expect_apps=${ingress_vip}
	fi
	local fqdn_api="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
	local fqdn_apps="okd-pve-preflight-${RANDOM}.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
	pf_dns "${fqdn_api}" "${expect_api}" "api"
	pf_dns "${fqdn_apps}" "${expect_apps}" "*.apps"
	[[ ${platform} == none ]] && pf_dns "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}" "${expect_api}" "api-int"

	local existing=${#PF_OWNED_VMIDS[@]}
	if state_step_done vms || ((existing > 0)); then
		pf INFO "VMs of this cluster already exist; skipping 'address is free' checks"
	elif have_cmd ping || have_cmd timeout; then
		local ip busy=()
		if [[ ${platform} == baremetal ]]; then
			for ip in "${api_vip}" "${ingress_vip}"; do
				host_answers "${ip}" && busy+=("VIP ${ip}")
			done
		fi
		while IFS= read -r ip; do
			host_answers "${ip}" && busy+=("${ip}")
		done < <(nodes_query '.[].ip')
		if ((${#busy[@]})); then
			pf FAIL "Addresses already answer: ${busy[*]}" "These IPs are in use; pick free addresses or shut down the old cluster."
		else
			pf PASS "VIPs and node IPs do not answer (free)"
		fi
	fi

	local gw
	gw=$(cfg '.network.gateway')
	if have_cmd ping; then
		if ping -c 1 -W 2 "${gw}" >/dev/null 2>&1; then
			pf PASS "Gateway ${gw} answers"
		else
			pf WARN "Gateway ${gw} does not answer ICMP from here" \
				"Fine if this workstation is in another network or ICMP is filtered; otherwise check network.gateway."
		fi
	fi

	pf_ntp
}

pf_dns() {
	local name=$1 want=$2 label=$3 got server at
	got=$(resolve_ipv4 "${name}" | paste -sd, -)
	if [[ -z ${got} ]]; then
		pf FAIL "DNS: ${label} (${name}) does not resolve" "Create an A record pointing to ${want}."
		return
	fi
	if [[ ,${got}, == *",${want},"* ]]; then
		pf PASS "DNS: ${label} resolves to ${want}"
	else
		pf FAIL "DNS: ${label} (${name}) resolves to ${got}, expected ${want}" "Fix the DNS record."
		return
	fi
	have_cmd dig || return 0
	for server in $(cfg '.network.dns_servers'); do
		at=$(resolve_ipv4_at "${server}" "${name}" | paste -sd, -)
		if [[ -z ${at} ]]; then
			pf WARN "DNS: ${label} not resolvable via cluster DNS server ${server} (or ${server} unreachable from here)" \
				"The nodes use network.dns_servers; make sure the record exists there."
		elif [[ ,${at}, != *",${want},"* ]]; then
			pf FAIL "DNS: ${label} resolves to ${at} via ${server}, expected ${want}" "Fix the record on ${server}."
		fi
	done
}

pf_ntp() {
	local -a servers
	mapfile -t servers < <(cfg '.network.ntp_servers')
	case ${#servers[@]} in
	0) ;;
	1) pf WARN "Only one NTP server configured" "Use at least 3 sources so chrony can detect a bad one." ;;
	2) pf WARN "Only two NTP servers configured" \
		"With two sources chrony cannot tell which one is wrong when they disagree (no majority). Use 3 or more." ;;
	*) pf PASS "${#servers[@]} NTP servers configured" ;;
	esac
	have_cmd timeout || return 0
	local s t ref='' now offset
	for s in "${servers[@]}"; do
		if t=$(ntp_query "${s}"); then
			pf PASS "NTP server ${s} answers"
			[[ -n ${ref} ]] || ref=${t}
		else
			pf WARN "NTP server ${s} does not answer from here" \
				"Fine if only the cluster network can reach it; otherwise check network.ntp_servers."
		fi
	done
	[[ -n ${ref} ]] || return 0
	now=$(date +%s)
	offset=$((now - ref))
	offset=${offset#-}
	if ((offset <= 2)); then
		pf PASS "Local clock is within ${offset}s of NTP"
	elif ((offset <= 60)); then
		pf WARN "Local clock is ${offset}s off" "Certificates are issued locally; enable time sync on this workstation."
	else
		pf FAIL "Local clock is ${offset}s off" \
			"The installer signs certificates with the local clock; nodes would reject them as not yet valid. Sync this machine's time."
	fi
}
