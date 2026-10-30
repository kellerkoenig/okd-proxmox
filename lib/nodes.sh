# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Node roles, infra labels/taints and scaling (node add/remove/list).
#
# Proxmox has no Machine API: there are no MachineSets and no autoscaling.
# Infra nodes are regular VMs installed as workers; okd-pve labels and
# taints them after they joined.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_NODES_LOADED:-} ]] && return 0
_OKD_PVE_NODES_LOADED=1

INFRA_LABEL="node-role.kubernetes.io/infra"

# cluster_api_init: oc + kubeconfig for commands that talk to the cluster.
cluster_api_init() {
	[[ -f ${KUBECONFIG_FILE} ]] || die "${EXIT_ERROR}" "No kubeconfig at ${KUBECONFIG_FILE}." \
		"Run 'okd-pve create' first (or copy the kubeconfig there)."
	tools_ensure oc
	export KUBECONFIG=${KUBECONFIG_FILE}
	PATH=$(dirname "${OC}"):${PATH}
	export PATH
	[[ -f ${AUTH_DIR}/kubeadmin-password ]] && redact_register "$(cat "${AUTH_DIR}/kubeadmin-password")"
	return 0
}

infra_taint_effects() {
	cfg '.infra.taint_effects'
}

# nodes_reconcile_labels: make infra labels, taints and the infra pool match
# cluster.yaml. Idempotent; used by create, node add and hook 10.
nodes_reconcile_labels() {
	local key value effect name infra taint changed=0
	key=$(cfg '.infra.taint_key')
	value=$(cfg '.infra.taint_value')
	if infra_pool_enabled && ! oc get machineconfigpool infra >/dev/null 2>&1 &&
		! dry_run_note "would create the infra MachineConfigPool"; then
		TPL=()
		render_template "$(_preboot_tpl infra-mcp.yaml.tpl)" | apply_idempotent - >/dev/null
		log_ok "Created MachineConfigPool infra"
	fi
	while IFS=$'\t' read -r name infra taint; do
		if ! oc get node "${name}" >/dev/null 2>&1; then
			log_warn "Node ${name} is not registered in the cluster; skipping labels"
			continue
		fi
		if [[ ${infra} == true ]] && ! node_has_label "${name}" "${INFRA_LABEL}"; then
			if ! dry_run_note "would label ${name} ${INFRA_LABEL}"; then
				node_set_label "${name}" "${INFRA_LABEL}" ""
				changed=1
			fi
		elif [[ ${infra} != true ]] && node_has_label "${name}" "${INFRA_LABEL}"; then
			if ! dry_run_note "would remove ${INFRA_LABEL} from ${name}"; then
				node_remove_label "${name}" "${INFRA_LABEL}"
				changed=1
			fi
		fi
		for effect in $(infra_taint_effects); do
			if [[ ${taint} == true ]] && ! node_has_taint "${name}" "${key}" "${value}" "${effect}"; then
				if ! dry_run_note "would taint ${name} ${key}=${value}:${effect}"; then
					node_set_taint "${name}" "${key}" "${value}" "${effect}"
					changed=1
				fi
			elif [[ ${taint} != true ]] && node_has_taint "${name}" "${key}" "${value}" "${effect}"; then
				if ! dry_run_note "would remove taint ${key}:${effect} from ${name}"; then
					node_remove_taint "${name}" "${key}" "${effect}"
					changed=1
				fi
			fi
		done
	done < <(nodes_query '.[] | select(.agent_role == "worker") | "\(.name)\t\(.infra)\t\(.taint_infra)"')
	if ((changed)); then
		log_ok "Infra labels and taints updated"
	else
		log_ok "Infra labels and taints are up to date"
	fi
}

# ---------------------------------------------------------------------------
# CSRs and readiness
# ---------------------------------------------------------------------------

# csr_approve_for <names...>: approve pending kubelet CSRs, but only those
# for the given node names (client CSRs from the node bootstrapper with
# CN=system:node:<name>, serving CSRs requested by system:node:<name>).
csr_approve_for() {
	local -A want=()
	local n csr user signer req cn
	for n in "$@"; do want[${n}]=1; done
	while IFS=$'\t' read -r csr user signer req; do
		case ${signer} in
		kubernetes.io/kube-apiserver-client-kubelet)
			[[ ${user} == system:serviceaccount:openshift-machine-config-operator:node-bootstrapper ]] || continue
			cn=$(base64 -d <<<"${req}" 2>/dev/null | sed '/-----/d' | base64 -d 2>/dev/null |
				LC_ALL=C grep -ao 'system:node:[A-Za-z0-9.-]*' | head -n1)
			cn=${cn#system:node:}
			;;
		kubernetes.io/kubelet-serving)
			cn=${user#system:node:}
			;;
		*) continue ;;
		esac
		[[ -n ${cn} && -n ${want[${cn}]:-} ]] || continue
		oc adm certificate approve "${csr}" >/dev/null && log_info "Approved CSR ${csr} for ${cn}"
	done < <(oc get csr -o json | jq -r '.items[]
		| select((.status.conditions // []) | length == 0)
		| [.metadata.name, .spec.username, .spec.signerName, .spec.request] | @tsv')
}

node_ready() {
	[[ $(oc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]
}

# nodes_join_wait <timeout-s> <names...>: approve CSRs until all nodes are Ready.
nodes_join_wait() {
	local timeout=$1 start=${SECONDS} n pending last=0
	shift
	while :; do
		csr_approve_for "$@"
		pending=()
		for n in "$@"; do node_ready "${n}" || pending+=("${n}"); done
		((${#pending[@]})) || break
		if ((SECONDS - start >= timeout)); then
			die "${EXIT_ERROR}" "Nodes not Ready after ${timeout}s: ${pending[*]}" \
				"Check the VM consoles (qm terminal <vmid>) and 'oc get csr'; re-run the command to continue."
		fi
		if ((SECONDS - last >= 120)); then
			log_info "Waiting for ${pending[*]} to join ($(elapsed "${start}"))"
			last=${SECONDS}
		fi
		sleep 15
	done
	log_ok "Nodes Ready: $*"
}

# ---------------------------------------------------------------------------
# node list
# ---------------------------------------------------------------------------

cmd_node_list() {
	local k8s='{}'
	if [[ -f ${KUBECONFIG_FILE} ]] && tool_check oc >/dev/null 2>&1; then
		cluster_api_init
		k8s=$(oc get nodes -o json --request-timeout=10s 2>/dev/null | jq -c '[.items[] | {key: .metadata.name, value: {
			ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown"),
			roles: ([.metadata.labels | keys[] | select(startswith("node-role.kubernetes.io/")) | sub("node-role.kubernetes.io/"; "")] | join(",")),
			taints: ([.spec.taints[]? | select(.key | startswith("node.kubernetes.io/") | not) | "\(.key | split("/") | last):\(.effect)"] | join(","))
		}}] | from_entries' || echo '{}')
	fi
	{
		echo "NAME|GROUP|ROLES (CONFIG)|VMID|HOST|IP|MAC|STATUS|ROLES (CLUSTER)|TAINTS"
		nodes_json | jq -r --argjson k "${k8s}" '.[] | [
			.name, .group, (.roles | join(",")), .vmid, .host, .ip, .mac,
			($k[.name].ready // "-" | if . == "True" then "Ready" elif . == "-" then "-" else "NotReady" end),
			($k[.name].roles // "-"), (($k[.name].taints // "") | if . == "" then "-" else . end)
		] | map(tostring) | join("|")'
	} | column -t -s '|'
}

# ---------------------------------------------------------------------------
# node add
# ---------------------------------------------------------------------------

# _pick_group <role> [group]: node group that receives new nodes.
_pick_group() {
	local role=$1 group=${2:-} candidates
	if [[ -n ${group} ]]; then
		jq -e --arg g "${group}" '.node_groups[] | select(.name == $g)' "${CONFIG_JSON}" >/dev/null ||
			die "${EXIT_CONFIG}" "Node group ${group} does not exist in cluster.yaml."
		printf '%s' "${group}"
		return
	fi
	if [[ ${role} == infra ]]; then
		candidates=$(jq -r '.node_groups[] | select((.roles | sort) == ["infra"]) | .name' "${CONFIG_JSON}")
		if [[ -z ${candidates} ]]; then
			local combined
			combined=$(jq -r '[.node_groups[] | select((.roles | index("infra")) and (.roles | length) > 1) | .name] | join(", ")' "${CONFIG_JSON}")
			if [[ -n ${combined} ]]; then
				log_error "Infra currently runs on combined worker/infra nodes (group ${combined}); there is no dedicated infra group."
				log_hint "Migration path to dedicated infra nodes:"
				log_hint "  1. Add a group with roles: [infra] and taint_infra: false and count: 0 to cluster.yaml."
				log_hint "  2. okd-pve node add --role infra --count 3   (new nodes join and get the infra label)"
				log_hint "  3. Remove 'infra' from the roles of group ${combined}, then: okd-pve node reconcile"
				log_hint "     Ingress, monitoring and registry now move to the new nodes; wait until they did."
				log_hint "  4. Set taint_infra: true on the new group, then: okd-pve node reconcile"
				log_hint "  Tainting before the components moved leaves them without a place to run."
				die "${EXIT_CONFIG}" "No dedicated infra group to add nodes to." "Follow the migration path above (docs/nodes.md)."
			fi
			die "${EXIT_CONFIG}" "No node group with the infra role." "Add a group with roles: [infra] to cluster.yaml."
		fi
		if jq -e '[.node_groups[] | select((.roles | index("infra")) and (.roles | length) > 1)] | length > 0' "${CONFIG_JSON}" >/dev/null; then
			log_warn "Combined worker/infra groups still carry the infra role. When the new infra nodes are Ready, remove 'infra' from those groups and run 'okd-pve node reconcile' (docs/nodes.md, migration path)."
		fi
	else
		candidates=$(jq -r '.node_groups[] | select(.roles | index("worker")) | .name' "${CONFIG_JSON}")
		[[ -n ${candidates} ]] || die "${EXIT_CONFIG}" "No node group with the worker role." "Add one to cluster.yaml."
	fi
	if (($(wc -l <<<"${candidates}") > 1)); then
		die "${EXIT_CONFIG}" "Several groups match role ${role}: $(paste -sd, - <<<"${candidates}")" "Select one with --group <name>."
	fi
	printf '%s' "${candidates}"
}

cmd_node_add() {
	local role='' count=1 group='' timeout=3600
	while (($#)); do
		case $1 in
		--role) role=${2:-} && shift 2 ;;
		--count) count=${2:-} && shift 2 ;;
		--group) group=${2:-} && shift 2 ;;
		--timeout) timeout=${2:-} && shift 2 ;;
		*) die "${EXIT_CONFIG}" "node add: unknown argument $1" "okd-pve node add --role worker|infra --count N [--group NAME]" ;;
		esac
	done
	[[ ${role} == worker || ${role} == infra ]] || die "${EXIT_CONFIG}" "node add needs --role worker or --role infra."
	[[ ${count} =~ ^[1-9][0-9]*$ ]] || die "${EXIT_CONFIG}" "--count must be a positive number."
	state_step_done install || die "${EXIT_ERROR}" "The cluster is not installed yet." "Run 'okd-pve create' first."

	group=$(_pick_group "${role}" "${group}")
	cluster_api_init
	tools_ensure tofu

	local inv new_idx
	state_inventory_freeze
	inv=$(state_inventory_get)
	new_idx=$(jq -c --arg g "${group}" --argjson n "${count}" \
		'(.[$g] // []) as $used | [range(0; 10000) | select(. as $i | $used | index($i) | not)] | .[0:$n]' <<<"${inv}")
	local new_inv
	new_inv=$(jq -c --arg g "${group}" --argjson add "${new_idx}" '.[$g] = ((.[$g] // []) + $add | sort)' <<<"${inv}")

	# Validate the node model with the new slots before touching anything.
	local names model
	model=$(jq_lib -c --arg cluster "${CLUSTER_NAME}" --argjson inv "${new_inv}" \
		'include "nodes"; nodes($cluster; $inv)' "${CONFIG_JSON}")
	names=$(jq -r --arg g "${group}" --argjson add "${new_idx}" \
		'.[] | select(.group == $g and (.index as $i | $add | index($i))) | .name' <<<"${model}")
	local errors
	errors=$(jq_lib -r -n --arg cluster "${CLUSTER_NAME}" --argjson inv "${new_inv}" \
		--slurpfile c "${CONFIG_JSON}" --slurpfile ic "${INSTALL_CONFIG_JSON}" \
		'include "validate"; $c[0] | validate($cluster; $inv; $ic[0]) | .errors[]')
	if [[ -n ${errors} ]]; then
		while IFS= read -r e; do log_error "${e}"; done <<<"${errors}"
		die "${EXIT_CONFIG}" "Cannot add ${count} node(s) to group ${group}." "Extend node_groups.${group}.ips or the VMID range."
	fi
	log_step "Adding ${count} node(s) to group ${group}: $(paste -sd' ' - <<<"${names}")"

	local work iso_key
	iso_key=add-$(date +%Y%m%d%H%M%S)
	work=${STATE_DIR}/node-add/${iso_key}
	if ((DRY_RUN)); then
		dry_run_note "would run 'oc adm node-image create' for: $(paste -sd' ' - <<<"${names}")"
		state_inventory_set_tmp "${new_inv}"
		tf_iso_register_tmp "${iso_key}"
		NODE_ADD_NAMES=$(jq -R . <<<"${names}" | jq -sc .)
		NODE_ADD_KEY=${iso_key}
		tf_node_isos() {
			jq -cn --argjson names "${NODE_ADD_NAMES}" --arg k "${NODE_ADD_KEY}" 'reduce $names[] as $n ({}; .[$n] = $k)'
		}
		tf_plan
		dry_run_note "would wait for CSRs, approve them, wait for Ready, set labels/taints and update node_groups.${group}.count in cluster.yaml"
		return 0
	fi

	mkdir -p "${work}"
	jq --argjson names "$(jq -R . <<<"${names}" | jq -sc .)" 'map(select(.name as $n | $names | index($n)))' <<<"${model}" |
		agent_hosts_yaml >"${work}/nodes-config.yaml"
	log_info "oc adm node-image create (builds the node ISO inside the cluster)"
	run_logged oc adm node-image create --dir "${work}" ||
		die "${EXIT_ERROR}" "oc adm node-image create failed." "See ${LOG_FILE}. The cluster must run OKD >= 4.17."
	local iso
	iso=$(find "${work}" -maxdepth 1 -name 'node.*.iso' | head -n1)
	[[ -n ${iso} ]] || die "${EXIT_ERROR}" "oc adm node-image create produced no ISO in ${work}."

	state_inventory_set "${new_inv}"
	local hosts
	hosts=$(nodes_json | jq -c --argjson names "$(jq -R . <<<"${names}" | jq -sc .)" '[.[] | select(.name as $n | $names | index($n)) | .host] | unique')
	tf_iso_register "${iso_key}" "${iso}" "${hosts}"
	local node_isos
	node_isos=$(tf_node_isos | jq -c --arg k "${iso_key}" --argjson names "$(jq -R . <<<"${names}" | jq -sc .)" \
		'reduce $names[] as $n (.; .[$n] = $k)')
	tf_node_isos_set "${node_isos}"
	log_info "Creating VMs (existing VMs are not touched)"
	tf_apply

	# shellcheck disable=SC2046
	nodes_join_wait "${timeout}" $(paste -sd' ' - <<<"${names}")

	log_info "Detaching the node ISO"
	tf_node_isos_set "$(tf_node_isos | jq -c --argjson names "$(jq -R . <<<"${names}" | jq -sc .)" 'with_entries(select(.key as $k | $names | index($k) | not))')"
	tf_iso_unregister "${iso_key}"
	tf_apply
	rm -rf "${work}"

	nodes_reconcile_labels
	config_set_count "${group}" "$(jq -r --arg g "${group}" '.[$g] | length' <<<"${new_inv}")"
	log_ok "Added $(paste -sd' ' - <<<"${names}")"
}

# Dry-run helpers: compute the plan with the new slots without persisting.
state_inventory_set_tmp() {
	local f=${OKD_PVE_TMP}/inventory.json
	printf '%s' "$1" >"${f}"
	state_inventory_get() { cat "${OKD_PVE_TMP}/inventory.json"; }
	nodes_invalidate
}

tf_iso_register_tmp() {
	local key=$1 placeholder=${OKD_PVE_TMP}/placeholder.iso
	: >"${placeholder}"
	local isos
	isos=$(tf_isos_json | jq -c --arg k "${key}" --arg p "${placeholder}" --arg f "$(tf_iso_file_name "${key}" "${placeholder}")" \
		--argjson h "$(nodes_query '[.[].host] | unique')" '.[$k] = {path: $p, file_name: $f, hosts: $h}')
	tf_isos_json() { cat "${OKD_PVE_TMP}/isos.json"; }
	printf '%s' "${isos}" >"${OKD_PVE_TMP}/isos.json"
}

# agent_hosts_yaml: nodes-config.yaml for `oc adm node-image create` from
# node JSON on stdin.
agent_hosts_yaml() {
	jq_lib --slurpfile c "${CONFIG_JSON}" 'include "nodes"; $c[0] as $c | {hosts: [.[] | agent_host($c)]}' | yq -P '.'
}

# config_set_count <group> <count>: write the new count back to cluster.yaml
# so a rebuild reproduces the current topology.
config_set_count() {
	((DRY_RUN)) && return 0
	cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
	G=$1 N=$2 yq -i '(.node_groups[] | select(.name == strenv(G)) | .count) = env(N)' "${CONFIG_FILE}"
	log_info "cluster.yaml: node_groups.$1.count = $2 (backup: ${CONFIG_FILE##*/}.bak)"
}

# ---------------------------------------------------------------------------
# node remove
# ---------------------------------------------------------------------------

cmd_node_remove() {
	local name='' force_cp=0 drain_timeout=10m
	while (($#)); do
		case $1 in
		--force-control-plane) force_cp=1 && shift ;;
		--drain-timeout) drain_timeout=${2:-} && shift 2 ;;
		-*) die "${EXIT_CONFIG}" "node remove: unknown option $1" ;;
		*) name=$1 && shift ;;
		esac
	done
	[[ -n ${name} ]] || die "${EXIT_CONFIG}" "node remove needs a node name." "See 'okd-pve node list'."
	state_inventory_freeze
	local node
	node=$(nodes_json | jq -c --arg n "${name}" '.[] | select(.name == $n)')
	[[ -n ${node} ]] || die "${EXIT_CONFIG}" "${name} is not a node of this cluster." "See 'okd-pve node list'."

	if [[ $(jq -r .agent_role <<<"${node}") == master ]]; then
		((force_cp)) || die "${EXIT_ERROR}" "${name} is a control-plane node; refusing to remove it." \
			"Removing a control-plane node breaks etcd quorum unless you replace it. Use --force-control-plane only if you know what you do."
		log_warn "Removing CONTROL-PLANE node ${name}. The etcd member is NOT removed automatically; remove it from etcd yourself (see OKD docs: replacing an unhealthy etcd member)."
	fi
	if [[ $(jq -r .infra <<<"${node}") == true ]] &&
		(($(nodes_query '[.[] | select(.infra)] | length') == 1)); then
		log_warn "${name} is the last infra node. Ingress and monitoring are pinned to infra nodes and will have nowhere to run."
	fi

	local group index
	group=$(jq -r .group <<<"${node}")
	index=$(jq -r .index <<<"${node}")
	log_step "Removing node ${name} (VMID $(jq -r .vmid <<<"${node}") on $(jq -r .host <<<"${node}"))"
	if ((DRY_RUN)); then
		dry_run_note "would cordon and drain ${name} (timeout ${drain_timeout}) and delete the node object"
		tools_ensure tofu
		tf_plan -destroy "$(tf_vm_target "${name}")"
		return 0
	fi
	if ! ((ASSUME_YES)); then
		confirm "Remove ${name} and delete its VM and disks?" || die "${EXIT_ERROR}" "Aborted."
	fi
	cluster_api_init
	tools_ensure tofu
	if oc get node "${name}" >/dev/null 2>&1; then
		log_info "Cordoning ${name}"
		run_logged oc adm cordon "${name}" || die "${EXIT_ERROR}" "cordon failed."
		log_info "Draining ${name} (timeout ${drain_timeout})"
		run_logged oc adm drain "${name}" --ignore-daemonsets --delete-emptydir-data --force --timeout="${drain_timeout}" ||
			die "${EXIT_ERROR}" "Draining ${name} failed or timed out." \
				"Check PodDisruptionBudgets ('oc get pdb -A'); retry with a longer --drain-timeout."
		run_logged oc delete node "${name}" || die "${EXIT_ERROR}" "oc delete node failed."
		log_ok "Node ${name} removed from the cluster"
	else
		log_warn "${name} is not registered in the cluster; only removing the VM"
	fi
	tf_destroy "$(tf_vm_target "${name}")"
	local inv
	inv=$(state_inventory_get | jq -c --arg g "${group}" --argjson i "${index}" '.[$g] = ((.[$g] // []) - [$i])')
	state_inventory_set "${inv}"
	tf_node_isos_set "$(tf_node_isos | jq -c --arg n "${name}" 'del(.[$n])')"
	config_set_count "${group}" "$(jq -r --arg g "${group}" '.[$g] | length' <<<"${inv}")"
	log_ok "Removed ${name}"
}

cmd_node_reconcile() {
	cluster_api_init
	log_step "Reconciling node labels and taints with cluster.yaml"
	nodes_reconcile_labels
}
