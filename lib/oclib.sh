# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Reusable oc helpers for okd-pve and for Post-Install hooks. Hooks source
# this file instead of writing their own wait loops:
#
#   source "${OKD_PVE_LIB_DIR}/oclib.sh"
#   install_operator cluster-logging stable-6.4 openshift-logging
#
# Requires: oc, jq, KUBECONFIG pointing at the cluster.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_OCLIB_LOADED:-} ]] && return 0
_OKD_PVE_OCLIB_LOADED=1

OCLIB_POLL_INTERVAL=${OCLIB_POLL_INTERVAL:-10}

_oclib_log() {
	local level=$1
	shift
	if declare -F log_info >/dev/null; then
		case ${level} in
		info) log_info "$*" ;;
		ok) log_ok "$*" ;;
		warn) log_warn "$*" ;;
		error) log_error "$*" ;;
		debug) log_debug "$*" ;;
		esac
	else
		[[ ${level} == debug && -z ${OKD_PVE_DEBUG:-} ]] && return 0
		printf '%s: %s\n' "${level}" "$*" >&2
	fi
}

# oc_wait <timeout-s> <description> <cmd...>: poll until cmd succeeds.
oc_wait() {
	local timeout=$1 desc=$2 start=${SECONDS} last=0
	shift 2
	until "$@"; do
		if ((SECONDS - start >= timeout)); then
			_oclib_log error "Timed out after ${timeout}s waiting for ${desc}"
			return 1
		fi
		if ((SECONDS - last >= 60)); then
			_oclib_log info "Waiting for ${desc} ($((SECONDS - start))s)"
			last=${SECONDS}
		fi
		sleep "${OCLIB_POLL_INTERVAL}"
	done
}

# ---------------------------------------------------------------------------
# Cluster state
# ---------------------------------------------------------------------------

# cluster_operators_not_ready: names of ClusterOperators that are not
# Available=True, Degraded=False, Progressing=False.
cluster_operators_not_ready() {
	oc get clusteroperators -o json | jq -r '
		.items[] | select(
			([.status.conditions[]? | select(.type == "Available" and .status == "True")] | length == 0) or
			([.status.conditions[]? | select(.type == "Degraded" and .status == "True")] | length > 0) or
			([.status.conditions[]? | select(.type == "Progressing" and .status == "True")] | length > 0)
		) | .metadata.name'
}

_cos_ready() {
	local out
	out=$(cluster_operators_not_ready 2>/dev/null) || return 1
	[[ -z ${out} ]] && return 0
	_oclib_log debug "ClusterOperators not ready: $(tr '\n' ' ' <<<"${out}")"
	return 1
}

# wait_for_cluster_operators [timeout-s=1800]
wait_for_cluster_operators() {
	oc_wait "${1:-1800}" "all ClusterOperators to be Available and not Progressing/Degraded" _cos_ready
}

_mcp_updated() {
	oc get machineconfigpool "$1" -o json 2>/dev/null | jq -e '
		(.status.conditions // []) as $c
		| ([$c[] | select(.type == "Updated" and .status == "True")] | length > 0)
		and ([$c[] | select(.type == "Degraded" and .status == "True")] | length == 0)
		and (.status.machineCount == .status.updatedMachineCount)' >/dev/null
}

# wait_for_mcp <pool> [timeout-s=3600]: wait until the MachineConfigPool is
# Updated. Needed after every MachineConfig applied after installation.
wait_for_mcp() {
	local pool=$1
	if oc get machineconfigpool "${pool}" -o json 2>/dev/null |
		jq -e '[.status.conditions[]? | select(.type == "Degraded" and .status == "True")] | length > 0' >/dev/null; then
		_oclib_log error "MachineConfigPool ${pool} is Degraded: $(oc get mcp "${pool}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}')"
		return 1
	fi
	oc_wait "${2:-3600}" "MachineConfigPool ${pool} to be Updated" _mcp_updated "${pool}"
}

_crd_established() {
	oc get crd "$1" -o json 2>/dev/null |
		jq -e '[.status.conditions[]? | select(.type == "Established" and .status == "True")] | length > 0' >/dev/null
}

# wait_for_crd <name> [timeout-s=600]
wait_for_crd() {
	oc_wait "${2:-600}" "CRD $1" _crd_established "$1"
}

# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------

_sub_installed_csv() {
	oc get subscription.operators.coreos.com "$1" -n "$2" -o jsonpath='{.status.installedCSV}' 2>/dev/null
}

_csv_succeeded() {
	local csv
	csv=$(_sub_installed_csv "$1" "$2")
	[[ -n ${csv} ]] || return 1
	[[ $(oc get csv "${csv}" -n "$2" -o jsonpath='{.status.phase}' 2>/dev/null) == Succeeded ]]
}

# install_operator <package> <channel> <namespace> [source] [source-namespace]
#
# Creates the namespace and an OperatorGroup if needed, subscribes, waits
# for the CSV to reach Succeeded and for every CRD the CSV owns to be
# established. Waiting for the CRDs matters: applying a custom resource right
# after the Subscription fails until its CRD is registered.
#
# channel "@default" uses the package's default channel from the catalog.
# OPERATOR_INSTALL_MODE=OwnNamespace|AllNamespaces overrides the install
# mode; by default it is taken from the operator's supported install modes.
install_operator() {
	local pkg=$1 channel=$2 ns=$3 source=${4:-redhat-operators} source_ns=${5:-openshift-marketplace}
	local timeout=${OPERATOR_TIMEOUT:-1200} mode=${OPERATOR_INSTALL_MODE:-} manifest

	if ! manifest=$(oc get packagemanifests -n "${source_ns}" -l "catalog=${source}" -o json 2>/dev/null |
		jq -ce --arg p "${pkg}" '.items[] | select(.metadata.name == $p)'); then
		_oclib_log error "Package ${pkg} not found in catalog ${source}. Is the catalog enabled (hook 20-operatorhub-catalogs) and does it contain ${pkg}?"
		return 1
	fi
	# "@default" follows the package's default channel in the catalog.
	[[ ${channel} == @default ]] && channel=$(jq -r '.status.defaultChannel' <<<"${manifest}")
	if ! jq -e --arg c "${channel}" '.status.channels[] | select(.name == $c)' <<<"${manifest}" >/dev/null; then
		_oclib_log error "Channel ${channel} does not exist for ${pkg} in ${source}. Available: $(jq -r '[.status.channels[].name] | join(", ")' <<<"${manifest}") (default: $(jq -r .status.defaultChannel <<<"${manifest}"))"
		return 1
	fi
	if [[ -z ${mode} ]]; then
		mode=$(jq -r --arg c "${channel}" --arg ns "${ns}" '
			[.status.channels[] | select(.name == $c) | .currentCSVDesc.installModes[]? | select(.supported) | .type] as $m
			| if ($ns != "openshift-operators") and ($m | index("OwnNamespace")) then "OwnNamespace"
			  else "AllNamespaces" end' <<<"${manifest}")
	fi

	oc get namespace "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}" >/dev/null
	oc label namespace "${ns}" openshift.io/cluster-monitoring=true --overwrite >/dev/null 2>&1 || true

	# openshift-operators already has a global OperatorGroup, and two
	# OperatorGroups in one namespace block every installation there.
	if [[ ${ns} != openshift-operators ]] &&
		[[ $(oc get operatorgroups -n "${ns}" -o json | jq '.items | length') == 0 ]]; then
		local spec="{targetNamespaces: [${ns}]}"
		[[ ${mode} == AllNamespaces ]] && spec='{}'
		oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}
  namespace: ${ns}
spec: ${spec}
EOF
	fi

	oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${ns}
spec:
  name: ${pkg}
  channel: ${channel}
  source: ${source}
  sourceNamespace: ${source_ns}
  installPlanApproval: Automatic
EOF
	_oclib_log info "Subscribed to ${pkg} (${channel} from ${source}), waiting for the operator"
	oc_wait "${timeout}" "operator ${pkg} (CSV Succeeded)" _csv_succeeded "${pkg}" "${ns}" || return 1

	local csv crd
	csv=$(_sub_installed_csv "${pkg}" "${ns}")
	while IFS= read -r crd; do
		[[ -n ${crd} ]] && { wait_for_crd "${crd}" 600 || return 1; }
	done < <(oc get csv "${csv}" -n "${ns}" -o json | jq -r '.spec.customresourcedefinitions.owned[]?.name')
	_oclib_log ok "Operator ${pkg} installed (${csv})"
}

# ---------------------------------------------------------------------------
# Applying resources
# ---------------------------------------------------------------------------

# apply_idempotent [file|dir|-]: always `oc apply`, never `oc create`, so
# hooks can run again. Reads stdin when no argument (or "-") is given.
#
# Objects an operator created (alertmanager-main, certmanagers/cluster) have
# no last-applied-configuration annotation; oc adds it on the first apply and
# warns about it. That one warning is dropped, everything else passes.
apply_idempotent() {
	local src=${1:--} err rc=0
	shift || true
	{ err=$(oc apply -f "${src}" "$@" 2>&1 1>&3 3>&-); } 3>&1 || rc=$?
	err=$(grep -v 'last-applied-configuration' <<<"${err}" || true)
	[[ -z ${err} ]] || printf '%s\n' "${err}" >&2
	return "${rc}"
}

# patch_merge <resource> <json-merge-patch> [oc-args...]: patch only when
# the live object does not already match, report what happened.
patch_merge() {
	local res=$1 patch=$2
	shift 2
	local current
	current=$(oc get "${res}" -o json "$@") || return 1
	if jq -e --argjson p "${patch}" '
		def satisfied($p):
			if ($p | type) == "object" then
				. as $o | ($o | type) == "object" and ($p | to_entries | all(
					if .value == null then ($o | has(.key) | not)
					else .value as $pv | ($o[.key] // null) | satisfied($pv) end))
			else . == $p end;
		satisfied($p)' <<<"${current}" >/dev/null; then
		_oclib_log debug "${res}: already up to date"
		return 0
	fi
	oc patch "${res}" --type merge -p "${patch}" "$@" >/dev/null
	_oclib_log info "${res}: patched"
}

# ---------------------------------------------------------------------------
# Service accounts
# ---------------------------------------------------------------------------

# sa_token <serviceaccount> <namespace> [--duration <d> | --long-lived]
#
# Default: a time-bound token via `oc create token` (TokenRequest API).
# --long-lived: creates (once) a Secret of type kubernetes.io/service-account-token
# and prints its token; such tokens do not expire.
#
# Do not use `oc serviceaccounts get-token` (removed with OCP 4.11) or read
# token secrets via `oc describe sa`: ServiceAccounts no longer get token
# secrets automatically.
sa_token() {
	local sa=$1 ns=$2 mode=${3:-} arg=${4:-}
	oc get serviceaccount "${sa}" -n "${ns}" >/dev/null 2>&1 || oc create serviceaccount "${sa}" -n "${ns}" >/dev/null
	if [[ ${mode} == --long-lived ]]; then
		local secret="${sa}-token-okd-pve"
		oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${ns}
  annotations:
    kubernetes.io/service-account.name: ${sa}
type: kubernetes.io/service-account-token
EOF
		oc_wait 120 "token in secret ${ns}/${secret}" _secret_has_token "${secret}" "${ns}" || return 1
		oc get secret "${secret}" -n "${ns}" -o jsonpath='{.data.token}' | base64 -d
		echo
	elif [[ ${mode} == --duration ]]; then
		oc create token "${sa}" -n "${ns}" --duration "${arg}"
	else
		oc create token "${sa}" -n "${ns}"
	fi
}

_secret_has_token() {
	[[ -n $(oc get secret "$1" -n "$2" -o jsonpath='{.data.token}' 2>/dev/null) ]]
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

# node_set_label <node> <key> [value]: idempotent.
node_set_label() {
	local node=$1 key=$2 value=${3:-}
	oc label node "${node}" "${key}=${value}" --overwrite >/dev/null
}

node_has_label() {
	oc get node "$1" -o json | jq -e --arg l "$2" '.metadata.labels | has($l)' >/dev/null
}

node_remove_label() {
	oc label node "$1" "$2-" >/dev/null 2>&1 || true
}

# node_has_taint <node> <key> <value> <effect>
node_has_taint() {
	oc get node "$1" -o json | jq -e --arg k "$2" --arg v "$3" --arg e "$4" \
		'[.spec.taints[]? | select(.key == $k and (.value // "") == $v and .effect == $e)] | length > 0' >/dev/null
}

# node_set_taint <node> <key> <value> <effect>: idempotent.
node_set_taint() {
	node_has_taint "$@" && return 0
	oc adm taint node "$1" "$2=$3:$4" --overwrite >/dev/null
}

node_remove_taint() {
	oc adm taint node "$1" "$2:$3-" >/dev/null 2>&1 || true
}

# infra_tolerations_json: tolerations matching the configured infra taint
# (OKD_PVE_INFRA_TAINT_KEY/_VALUE/_EFFECTS from the hook environment).
infra_tolerations_json() {
	local effects=${OKD_PVE_INFRA_TAINT_EFFECTS:-NoSchedule}
	jq -cn --arg k "${OKD_PVE_INFRA_TAINT_KEY:-node-role.kubernetes.io/infra}" \
		--arg v "${OKD_PVE_INFRA_TAINT_VALUE:-reserved}" --arg e "${effects}" \
		'[$e | split(" ")[] | select(. != "") | {key: $k, operator: "Equal", value: $v, effect: .}]'
}
