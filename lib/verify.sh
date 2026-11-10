# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Cluster health check (okd-pve verify).

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_VERIFY_LOADED:-} ]] && return 0
_OKD_PVE_VERIFY_LOADED=1

VF_FAIL=0
VF_WARN=0

vf() {
	local status=$1 msg=$2 hint=${3:-} color=''
	_log_to_file "VERIFY-${status}" "${msg}${hint:+ -- ${hint}}"
	case ${status} in
	PASS) color=${C_GREEN} ;;
	WARN) ((++VF_WARN)) && color=${C_YELLOW} ;;
	FAIL) ((++VF_FAIL)) && color=${C_RED} ;;
	SKIP) color=${C_DIM} ;;
	esac
	printf '    %s[%s]%s %s\n' "${color}" "${status}" "${C_RESET}" "$(redact_string "${msg}")"
	[[ -n ${hint} && ${status} != PASS ]] && printf '           %s-> %s%s\n' "${C_DIM}" "$(redact_string "${hint}")" "${C_RESET}"
	return 0
}

# verify_once [--no-storage]: one pass over all checks.
verify_once() {
	local no_storage=0
	[[ ${1:-} == --no-storage ]] && no_storage=1
	VF_FAIL=0 VF_WARN=0
	local nodes_json_k8s
	if ! nodes_json_k8s=$(oc get nodes -o json --request-timeout=20s 2>/dev/null); then
		vf FAIL "API not reachable with ${KUBECONFIG_FILE}" "Check the API VIP, DNS for api.${CLUSTER_NAME}.${BASE_DOMAIN} and the kubeconfig."
		return 1
	fi
	vf_nodes "${nodes_json_k8s}"
	vf_mcps
	vf_cluster_operators
	vf_csrs
	vf_endpoints
	vf_etcd
	if [[ $(jq -r '.verify.time_sync' "${CONFIG_JSON}") == true ]]; then
		vf_time_sync "${nodes_json_k8s}"
	fi
	vf_infra "${nodes_json_k8s}"
	vf_mirrors
	if ((no_storage)) && [[ $(cfg '.storage.backend') != none ]]; then
		vf SKIP "StorageClass check (storage is installed in the next step)"
	else
		vf_storage
	fi
	((VF_FAIL == 0))
}

vf_nodes() {
	local k8s=$1 want missing notready
	want=$(nodes_query '[.[].name]')
	missing=$(jq -r --argjson want "${want}" '[.items[].metadata.name] as $have | $want - $have | join(" ")' <<<"${k8s}")
	notready=$(jq -r '[.items[] | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0) | .metadata.name] | join(" ")' <<<"${k8s}")
	if [[ -n ${missing} ]]; then
		vf FAIL "Nodes not registered: ${missing}" "Check the VM consoles and pending CSRs (oc get csr)."
	fi
	if [[ -n ${notready} ]]; then
		vf FAIL "Nodes not Ready: ${notready}" "oc describe node <name>"
	elif [[ -z ${missing} ]]; then
		vf PASS "All $(jq '.items | length' <<<"${k8s}") nodes Ready"
	fi
}

vf_mcps() {
	local bad
	bad=$(oc get machineconfigpools -o json | jq -r '.items[]
		| select(([.status.conditions[]? | select(.type == "Updated" and .status == "True")] | length == 0)
			or ([.status.conditions[]? | select(.type == "Degraded" and .status == "True")] | length > 0))
		| "\(.metadata.name) (\(.status.updatedMachineCount // 0)/\(.status.machineCount // 0) updated\(if ([.status.conditions[]? | select(.type == "Degraded" and .status == "True")] | length > 0) then ", Degraded" else "" end))"' | paste -sd, -)
	if [[ -n ${bad} ]]; then
		vf FAIL "MachineConfigPools not updated: ${bad}" "oc get mcp; a Degraded pool often means a node matches two custom pools."
	else
		vf PASS "All MachineConfigPools Updated, none Degraded"
	fi
}

vf_cluster_operators() {
	local bad
	bad=$(cluster_operators_not_ready 2>/dev/null | paste -sd, -)
	if [[ -n ${bad} ]]; then
		vf FAIL "ClusterOperators not Available or Degraded/Progressing: ${bad}" "oc get co; oc describe co <name>"
	else
		vf PASS "All ClusterOperators Available, not Degraded"
	fi
}

vf_csrs() {
	local pending
	pending=$(oc get csr -o json | jq '[.items[] | select((.status.conditions // []) | length == 0)] | length')
	if ((pending > 0)); then
		vf WARN "${pending} pending CSR(s)" "Inspect with 'oc get csr' and approve the ones for known nodes."
	else
		vf PASS "No pending CSRs"
	fi
}

vf_endpoints() {
	local api="https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443/readyz"
	local console="https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/"
	local code
	code=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "${api}" 2>/dev/null || true)
	if [[ ${code} == 200 ]]; then
		vf PASS "API VIP answers (${api})"
	else
		vf FAIL "API VIP check ${api} returned ${code:-no answer}" "Check keepalived on the masters and DNS for api.${CLUSTER_NAME}.${BASE_DOMAIN}."
	fi
	code=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "${console}" 2>/dev/null || true)
	if [[ ${code} =~ ^(200|302|303)$ ]]; then
		vf PASS "Ingress VIP and console answer (${console})"
	else
		vf FAIL "Console ${console} returned ${code:-no answer}" "Check the ingress VIP, *.apps DNS and the router pods (oc -n openshift-ingress get pods -o wide)."
	fi
}

vf_etcd() {
	local msg status
	status=$(oc get etcd cluster -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type == "EtcdMembersAvailable") | "\(.status)\t\(.message)"')
	msg=${status#*$'\t'}
	if [[ ${status%%$'\t'*} == True ]]; then
		vf PASS "etcd quorum healthy (${msg})"
	else
		vf FAIL "etcd members not all available: ${msg:-unknown}" "oc -n openshift-etcd get pods; oc describe etcd cluster"
	fi
}

# vf_time_sync: chronyc tracking on every node via oc debug (in parallel).
vf_time_sync() {
	local k8s=$1 n dir bad=() fails=()
	dir=$(mktemp -d "${OKD_PVE_TMP}/chrony.XXXXXX")
	for n in $(jq -r '.items[].metadata.name' <<<"${k8s}"); do
		(timeout 180 oc debug "node/${n}" --quiet -- chroot /host chronyc -n tracking >"${dir}/${n}" 2>/dev/null || true) &
	done
	wait
	for n in $(jq -r '.items[].metadata.name' <<<"${k8s}"); do
		if ! grep -q 'Leap status *: Normal' "${dir}/${n}"; then
			if [[ -s ${dir}/${n} ]]; then bad+=("${n}"); else fails+=("${n}"); fi
		fi
	done
	if ((${#bad[@]})); then
		vf FAIL "Time not synchronised on: ${bad[*]}" "oc debug node/<name> -- chroot /host chronyc sources -v; check network.ntp_servers."
	elif ((${#fails[@]})); then
		vf WARN "Could not check time sync on: ${fails[*]}" "oc debug needs the tools image; retry later or set verify.time_sync: false."
	else
		vf PASS "Time synchronised on all nodes (chrony)"
	fi
}

vf_infra() {
	local k8s=$1 key value effects expected wrong=()
	expected=$(nodes_query '[.[] | select(.infra) | {name, taint: .taint_infra}]')
	if [[ ${expected} == '[]' ]]; then
		vf SKIP "No infra nodes configured"
		return
	fi
	key=$(cfg '.infra.taint_key')
	value=$(cfg '.infra.taint_value')
	effects=$(cfg_json '.infra.taint_effects')
	mapfile -t wrong < <(jq -r --argjson exp "${expected}" --arg k "${key}" --arg v "${value}" --argjson eff "${effects}" '
		(.items | map({key: .metadata.name, value: .}) | from_entries) as $nodes
		| $exp[] | . as $e | $nodes[$e.name] as $n
		| if $n == null then empty
		  elif ($n.metadata.labels | has("node-role.kubernetes.io/infra") | not) then "\($e.name): infra label missing"
		  else ([$n.spec.taints[]? | select(.key == $k and (.value // "") == $v) | .effect]) as $have
		  | if $e.taint and (($eff - $have) | length > 0) then "\($e.name): taint \($k)=\($v):\(($eff - $have) | join(",")) missing"
		    elif ($e.taint | not) and ($have | length > 0) then "\($e.name): unexpected infra taint"
		    else empty end
		  end' <<<"${k8s}")
	if ((${#wrong[@]})); then
		vf FAIL "Infra labels/taints: $(join_by '; ' "${wrong[@]}")" "Run 'okd-pve node reconcile'."
	else
		vf PASS "Infra nodes labeled and tainted as configured"
	fi
	local off
	off=$(oc -n openshift-ingress get pods -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o json 2>/dev/null |
		jq -r --argjson infra "$(nodes_query '[.[] | select(.infra) | .name]')" \
			'[.items[] | select(.spec.nodeName as $n | $infra | index($n) | not) | "\(.metadata.name)@\(.spec.nodeName // "pending")"] | join(" ")')
	if [[ -n ${off} ]]; then
		vf WARN "Ingress router pods not on infra nodes: ${off}" "Enable and run hook 30-ingress-controller (okd-pve hooks run 30-ingress-controller)."
	else
		vf PASS "Ingress router pods run on infra nodes"
	fi
}

# vf_mirrors: every registry_mirrors entry is in an ImageDigestMirrorSet and
# an ImageTagMirrorSet of the cluster.
vf_mirrors() {
	mirrors_enabled || return 0
	local idms itms missing
	if ! idms=$(oc get imagedigestmirrorset -o json --request-timeout=20s 2>/dev/null) ||
		! itms=$(oc get imagetagmirrorset -o json --request-timeout=20s 2>/dev/null); then
		vf WARN "Could not read the ImageDigestMirrorSets/ImageTagMirrorSets" "oc get idms,itms"
		return 0
	fi
	missing=$(jq -rn --argjson w "$(mirrors_json)" --argjson d "${idms}" --argjson t "${itms}" '
		def has($l; $m): any($l[]; .source == $m.source and ((.mirrors // []) | index($m.mirror)) != null);
		[$d.items[]?.spec.imageDigestMirrors[]?] as $dl | [$t.items[]?.spec.imageTagMirrors[]?] as $tl
		| [$w[] | select((has($dl; .) and has($tl; .)) | not) | .source] | join(", ")')
	if [[ -n ${missing} ]]; then
		vf WARN "Registry mirrors from cluster.yaml missing in the cluster: ${missing}" "Run 'okd-pve mirrors apply'."
	else
		vf PASS "Registry mirrors configured in the cluster ($(mirrors_json | jq length) source(s))"
	fi
}

vf_storage() {
	local backend sc
	backend=$(cfg '.storage.backend')
	if [[ ${backend} == none ]]; then
		vf SKIP "No storage backend configured"
		return
	fi
	sc=$(cfg '.storage.storage_class')
	if ! oc get storageclass "${sc}" >/dev/null 2>&1; then
		vf FAIL "StorageClass ${sc} missing" "Run 'okd-pve storage install'."
		return
	fi
	if [[ $(jq -r '.verify.storage_test' "${CONFIG_JSON}") != true ]]; then
		vf PASS "StorageClass ${sc} exists (functional test disabled)"
		return
	fi
	if storage_test_pvc "${sc}" >/dev/null 2>&1; then
		vf PASS "StorageClass ${sc} provisions and mounts a test volume"
	else
		vf FAIL "StorageClass ${sc} failed the test PVC" "See 'okd-pve storage install' output and the CSI driver pods."
	fi
}

cmd_verify() {
	local wait=0 timeout=3600 no_storage=0
	while (($#)); do
		case $1 in
		--wait) wait=1 && shift ;;
		--timeout) timeout=${2:-} && shift 2 ;;
		--no-storage) no_storage=1 && shift ;;
		*) die "${EXIT_CONFIG}" "verify: unknown argument $1" "okd-pve verify [--wait] [--timeout SECONDS]" ;;
		esac
	done
	cluster_api_init
	local start=${SECONDS} args=()
	((no_storage)) && args=(--no-storage)
	while :; do
		log_step "Verifying cluster ${CLUSTER_NAME}.${BASE_DOMAIN}"
		if verify_once "${args[@]+"${args[@]}"}"; then
			log_ok "Cluster is healthy (${VF_WARN} warning(s))"
			return 0
		fi
		((wait)) || break
		if ((SECONDS - start >= timeout)); then
			break
		fi
		log_info "Not healthy yet (${VF_FAIL} failure(s)); checking again in 60s ($(elapsed "${start}") elapsed)"
		sleep 60
	done
	die "${EXIT_ERROR}" "Cluster verification failed (${VF_FAIL} failure(s))." \
		"Fix the items above, or use 'okd-pve verify --wait' while the cluster is still settling."
}
