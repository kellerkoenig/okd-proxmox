# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Locating the cluster directory and loading/validating the three
# configuration files: install-config.yaml, cluster.yaml, proxmox.conf.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_CONFIG_LOADED:-} ]] && return 0
_OKD_PVE_CONFIG_LOADED=1

CLUSTER_DIR=${CLUSTER_DIR:-}
CONFIG_FILE=${CONFIG_FILE:-}
CONFIG_JSON=''
CLUSTER_NAME=''
BASE_DOMAIN=''

# Keys read from proxmox.conf. Environment variables take precedence.
PROXMOX_CONF_KEYS=(PROXMOX_VE_ENDPOINT PROXMOX_VE_API_TOKEN PROXMOX_VE_INSECURE)

# OKD clusters without a Red Hat pull secret use this placeholder.
OKD_FAKE_PULL_SECRET='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

set_cluster_paths() {
	CLUSTER_DIR=$(cd "$1" && pwd)
	CONFIG_FILE=${CONFIG_FILE:-${CLUSTER_DIR}/cluster.yaml}
	INSTALL_CONFIG_FILE=${CLUSTER_DIR}/install-config.yaml
	PROXMOX_CONF_FILE=${OKD_PVE_PROXMOX_CONF:-${CLUSTER_DIR}/proxmox.conf}
	GENERATED_DIR=${CLUSTER_DIR}/.generated
	STATE_DIR=${CLUSTER_DIR}/.state
	TOFU_DIR=${CLUSTER_DIR}/tofu
	BIN_DIR=${CLUSTER_DIR}/bin
	AUTH_DIR=${CLUSTER_DIR}/auth
	LOG_DIR=${CLUSTER_DIR}/logs
	PREBOOT_USER_DIR=${CLUSTER_DIR}/preboot
	KUBECONFIG_FILE=${AUTH_DIR}/kubeconfig
}

# resolve_cluster_dir [--dir value]: --dir wins; otherwise the current
# directory if it holds a cluster.yaml; otherwise ./clusters/<only-one>.
resolve_cluster_dir() {
	local dir=${1:-}
	if [[ -n ${dir} ]]; then
		[[ -d ${dir} ]] || die "${EXIT_CONFIG}" "Cluster directory ${dir} does not exist." \
			"Create it with: okd-pve init <name> --dir ${dir}"
		set_cluster_paths "${dir}"
		return
	fi
	if [[ -f ./cluster.yaml ]]; then
		set_cluster_paths .
		return
	fi
	local candidates=()
	if [[ -d ./clusters ]]; then
		local d
		for d in ./clusters/*/; do
			[[ -f ${d}cluster.yaml ]] && candidates+=("${d%/}")
		done
	fi
	case ${#candidates[@]} in
	1) set_cluster_paths "${candidates[0]}" ;;
	0) die "${EXIT_CONFIG}" "No cluster directory found." \
		"Run 'okd-pve init <name>' or pass --dir <cluster-dir>." ;;
	*) die "${EXIT_CONFIG}" "Several clusters found under ./clusters: ${candidates[*]##*/}" \
		"Select one with --dir clusters/<name>." ;;
	esac
}

# ---------------------------------------------------------------------------
# Tools needed to read configuration at all
# ---------------------------------------------------------------------------

require_config_tools() {
	have_cmd jq || die "${EXIT_CONFIG}" "jq is required but not installed." \
		"Install it: apt install jq | dnf install jq | brew install jq"
	have_cmd yq || die "${EXIT_CONFIG}" "yq (mikefarah, v4) is required but not installed." \
		"Install it from https://github.com/mikefarah/yq/releases (the Python yq is not compatible)."
	if ! yq --version 2>&1 | grep -q 'mikefarah'; then
		die "${EXIT_CONFIG}" "The yq in PATH is not mikefarah/yq v4 ($(yq --version 2>&1 | head -n1))." \
			"Install mikefarah/yq v4 and put it first in PATH."
	fi
}

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

# config_load: merge defaults with cluster.yaml, read install-config.yaml.
config_load() {
	require_config_tools
	[[ -f ${CONFIG_FILE} ]] || die "${EXIT_CONFIG}" "Missing ${CONFIG_FILE}." \
		"Run 'okd-pve init <name>' to create a commented template."
	[[ -f ${INSTALL_CONFIG_FILE} ]] || die "${EXIT_CONFIG}" "Missing ${INSTALL_CONFIG_FILE}." \
		"Run 'okd-pve init <name>' to create a commented template."

	setup_tmp
	CONFIG_JSON=${OKD_PVE_TMP}/config.json
	local err
	if ! err=$(yq -o json eval-all '. as $item ireduce ({}; . * $item)' \
		"${OKD_PVE_ROOT}/templates/cluster-defaults.yaml" "${CONFIG_FILE}" 2>&1 >"${CONFIG_JSON}"); then
		die "${EXIT_CONFIG}" "Cannot parse ${CONFIG_FILE}: ${err}" "Fix the YAML syntax."
	fi
	INSTALL_CONFIG_JSON=${OKD_PVE_TMP}/install-config.json
	if ! err=$(yq -o json '.' "${INSTALL_CONFIG_FILE}" 2>&1 >"${INSTALL_CONFIG_JSON}"); then
		die "${EXIT_CONFIG}" "Cannot parse ${INSTALL_CONFIG_FILE}: ${err}" "Fix the YAML syntax."
	fi
	CLUSTER_NAME=$(jq -r '.metadata.name // empty' "${INSTALL_CONFIG_JSON}")
	BASE_DOMAIN=$(jq -r '.baseDomain // empty' "${INSTALL_CONFIG_JSON}")
	# The node model needs the base domain for {domain} in hostname_format.
	jq --arg d "${BASE_DOMAIN}" '.cluster_meta = {base_domain: $d}' "${CONFIG_JSON}" >"${CONFIG_JSON}.tmp"
	mv "${CONFIG_JSON}.tmp" "${CONFIG_JSON}"
	[[ -n ${CLUSTER_NAME} ]] || die "${EXIT_CONFIG}" "install-config.yaml: metadata.name is missing." \
		"Set metadata.name to the cluster name."
	[[ -n ${BASE_DOMAIN} ]] || die "${EXIT_CONFIG}" "install-config.yaml: baseDomain is missing." \
		"Set baseDomain, for example example.com."
	NODES_JSON=''
	export CLUSTER_NAME BASE_DOMAIN
}

# cfg <jq-filter>: read a scalar from the merged cluster configuration.
cfg() {
	jq -r "($1) | if . == null then empty elif type == \"array\" then .[] else . end" "${CONFIG_JSON}"
}

# cfg_json <jq-filter>: compact JSON of a configuration value.
cfg_json() {
	jq -c "$1" "${CONFIG_JSON}"
}

# ic <jq-filter>: read from install-config.yaml.
ic() {
	jq -r "($1) | if . == null then empty elif type == \"array\" then .[] else . end" "${INSTALL_CONFIG_JSON}"
}

# jq_lib <args...>: jq with the project's jq modules on the search path.
jq_lib() {
	jq -L "${OKD_PVE_ROOT}/lib/jq" "$@"
}

# nodes_json: all nodes as a JSON array (cached per run).
nodes_json() {
	if [[ -z ${NODES_JSON:-} || ! -f ${NODES_JSON} ]]; then
		NODES_JSON=${OKD_PVE_TMP}/nodes.json
		local inv
		inv=$(state_inventory_get)
		jq_lib --arg cluster "${CLUSTER_NAME}" --argjson inv "${inv}" \
			'include "nodes"; nodes($cluster; $inv)' "${CONFIG_JSON}" >"${NODES_JSON}"
	fi
	cat "${NODES_JSON}"
}

nodes_invalidate() {
	NODES_JSON=''
}

# nodes_query [jq-args...] <jq-filter>: run a filter over the node list.
nodes_query() {
	nodes_json | jq -r "$@"
}

# infra_pool_enabled: true when a dedicated infra MachineConfigPool is used.
infra_pool_enabled() {
	[[ $(jq_lib 'include "nodes"; infra_pool_enabled' "${CONFIG_JSON}") == true ]]
}

pool_name() {
	local p
	p=$(cfg '.proxmox.pool')
	printf '%s' "${p:-okd-${CLUSTER_NAME}}"
}

monitoring_storage_class() {
	local sc
	sc=$(cfg '.monitoring.storage_class')
	[[ -n ${sc} ]] || { [[ $(cfg '.storage.backend') != none ]] && sc=$(cfg '.storage.storage_class'); }
	printf '%s' "${sc}"
}

okd_minor() {
	cfg '.okd.version' | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
}

platform_type() {
	if [[ $(ic '.platform | keys | .[0]') == none ]]; then
		printf none
	else
		printf baremetal
	fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# config_validate [--quiet]: static checks, dies with exit code 2 on errors.
config_validate() {
	local quiet=0 result inv
	[[ ${1:-} == --quiet ]] && quiet=1
	inv=$(state_inventory_get)
	result=$(jq_lib -n --arg cluster "${CLUSTER_NAME}" --argjson inv "${inv}" \
		--slurpfile c "${CONFIG_JSON}" --slurpfile ic "${INSTALL_CONFIG_JSON}" \
		'include "validate"; $c[0] | validate($cluster; $inv; $ic[0])')
	local -a errors warnings
	mapfile -t errors < <(jq -r '.errors[]' <<<"${result}")
	mapfile -t warnings < <(jq -r '.warnings[]' <<<"${result}")
	# install-config checks need a valid node model, so they run second.
	((${#errors[@]})) || mapfile -t errors < <(
		install_config_errors
		mirrors_config_errors
	)
	if ((! quiet)); then
		local w
		for w in "${warnings[@]+"${warnings[@]}"}"; do log_warn "${w}"; done
	fi
	if ((${#errors[@]})); then
		local e
		for e in "${errors[@]}"; do log_error "${e}"; done
		die "${EXIT_CONFIG}" "Configuration is invalid (${#errors[@]} error(s))." \
			"Fix ${CONFIG_FILE##*/} / install-config.yaml and run 'okd-pve preflight'."
	fi
}

# install_config_errors: one error per line for install-config.yaml.
install_config_errors() {
	local masters workers platform
	masters=$(nodes_query '[.[] | select(.agent_role == "master")] | length')
	workers=$(nodes_query '[.[] | select(.agent_role == "worker")] | length')
	platform=$(jq -r '.platform // {} | keys | join(",")' "${INSTALL_CONFIG_JSON}")
	[[ $(ic '.apiVersion') == v1 ]] || echo "install-config.yaml: apiVersion must be v1"
	case ${platform} in
	baremetal)
		[[ -n $(ic '.platform.baremetal.apiVIP') || -n $(ic '.platform.baremetal.ingressVIP') ]] &&
			echo "install-config.yaml: use platform.baremetal.apiVIPs/ingressVIPs (lists) instead of the deprecated apiVIP/ingressVIP"
		[[ -n $(ic '.platform.baremetal.apiVIPs[0]') ]] || echo "install-config.yaml: platform.baremetal.apiVIPs is required"
		[[ -n $(ic '.platform.baremetal.ingressVIPs[0]') ]] || echo "install-config.yaml: platform.baremetal.ingressVIPs is required"
		[[ -n $(ic '.platform.baremetal.hosts[0]') ]] &&
			echo "install-config.yaml: remove platform.baremetal.hosts; hosts are generated into agent-config.yaml"
		((masters == 1)) &&
			echo "install-config.yaml: a single-node cluster needs 'platform: {none: {}}' (the agent installer does not support baremetal VIPs with one node)"
		;;
	none)
		((masters == 1)) ||
			echo "install-config.yaml: 'platform: none' is only supported for single-node clusters here; use platform.baremetal with apiVIPs/ingressVIPs"
		;;
	*) echo "install-config.yaml: platform must be 'baremetal' (or 'none' for single node), found '${platform:-<empty>}'" ;;
	esac
	local cp_replicas compute_replicas
	cp_replicas=$(ic '.controlPlane.replicas')
	compute_replicas=$(ic '.compute[0].replicas')
	[[ -z ${cp_replicas} || ${cp_replicas} == "${masters}" ]] ||
		echo "install-config.yaml: controlPlane.replicas (${cp_replicas}) does not match the master group count (${masters}); remove the field or make them equal"
	if [[ -n ${compute_replicas} && ${compute_replicas} != "${workers}" ]] && ! state_step_done vms; then
		echo "install-config.yaml: compute[0].replicas (${compute_replicas}) does not match the number of non-master nodes (${workers}); remove the field or make them equal"
	fi
	[[ -n $(ic '.networking.machineNetwork[0].cidr') ]] ||
		echo "install-config.yaml: networking.machineNetwork[0].cidr is required"
	if [[ -n $(ic '.pullSecret') ]] && ! jq -e '.auths | type == "object"' <<<"$(ic '.pullSecret')" >/dev/null 2>&1; then
		echo "install-config.yaml: pullSecret is not valid JSON with an 'auths' object"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# proxmox.conf
# ---------------------------------------------------------------------------

# proxmox_conf_load: source proxmox.conf (credentials only). Refuses files
# readable by group or others. Environment variables override the file.
proxmox_conf_load() {
	local -A from_env=()
	local k
	for k in "${PROXMOX_CONF_KEYS[@]}"; do
		[[ -n ${!k+x} ]] && from_env[${k}]=${!k}
	done
	if [[ -f ${PROXMOX_CONF_FILE} ]]; then
		local mode
		mode=$(file_mode "${PROXMOX_CONF_FILE}")
		if (((8#${mode} & 8#077) != 0)); then
			die "${EXIT_CONFIG}" "${PROXMOX_CONF_FILE} is accessible by group/others (mode ${mode})." \
				"Run: chmod 600 ${PROXMOX_CONF_FILE}"
		fi
		# shellcheck disable=SC1090
		source "${PROXMOX_CONF_FILE}"
	fi
	for k in "${!from_env[@]}"; do
		printf -v "${k}" '%s' "${from_env[${k}]}"
	done
	PROXMOX_VE_INSECURE=${PROXMOX_VE_INSECURE:-false}
	[[ -n ${PROXMOX_VE_ENDPOINT:-} ]] || die "${EXIT_CONFIG}" "PROXMOX_VE_ENDPOINT is not set." \
		"Set it in ${PROXMOX_CONF_FILE} or the environment, e.g. https://pve.example.com:8006/"
	[[ -n ${PROXMOX_VE_API_TOKEN:-} ]] || die "${EXIT_CONFIG}" "PROXMOX_VE_API_TOKEN is not set." \
		"Set it in ${PROXMOX_CONF_FILE} or the environment (format user@realm!tokenid=secret). See docs/proxmox-permissions.md."
	if [[ ! ${PROXMOX_VE_API_TOKEN} =~ ^[^!@[:space:]]+@[^!@[:space:]]+![^=[:space:]]+=[^[:space:]]+$ ]]; then
		redact_register "${PROXMOX_VE_API_TOKEN}"
		die "${EXIT_CONFIG}" "PROXMOX_VE_API_TOKEN has the wrong format." \
			"Expected user@realm!tokenid=secret (see docs/proxmox-permissions.md)."
	fi
	register_proxmox_secrets
	export PROXMOX_VE_ENDPOINT PROXMOX_VE_API_TOKEN PROXMOX_VE_INSECURE
}

register_proxmox_secrets() {
	redact_register "${PROXMOX_VE_API_TOKEN}" "${PROXMOX_VE_API_TOKEN#*=}"
}

# ---------------------------------------------------------------------------
# Pull secret and SSH key
# ---------------------------------------------------------------------------

# pull_secret_value: install-config > $OKD_PVE_PULL_SECRET_FILE >
# install.pull_secret_file > <cluster>/pull-secret.json > OKD placeholder,
# plus the credentials of registry_mirrors.auth_file.
pull_secret_value() {
	_pull_secret_base | mirrors_merge_auth
}

_pull_secret_base() {
	local v f
	v=$(ic '.pullSecret')
	if [[ -n ${v} ]]; then
		printf '%s' "${v}"
		return
	fi
	for f in "${OKD_PVE_PULL_SECRET_FILE:-}" "$(cfg '.install.pull_secret_file')" "${CLUSTER_DIR}/pull-secret.json"; do
		[[ -n ${f} ]] || continue
		f=$(resolve_path "${f}")
		if [[ -f ${f} ]]; then
			jq -c . "${f}"
			return
		fi
	done
	printf '%s' "${OKD_FAKE_PULL_SECRET}"
}

pull_secret_source() {
	local f
	[[ -n $(ic '.pullSecret') ]] && {
		echo "install-config.yaml"
		return
	}
	for f in "${OKD_PVE_PULL_SECRET_FILE:-}" "$(cfg '.install.pull_secret_file')" "${CLUSTER_DIR}/pull-secret.json"; do
		[[ -n ${f} ]] || continue
		f=$(resolve_path "${f}")
		[[ -f ${f} ]] && {
			echo "${f}"
			return
		}
	done
	echo "built-in OKD placeholder"
}

# register_pull_secret: mask the auth strings of the pull secret.
register_pull_secret() {
	local a
	while IFS= read -r a; do
		redact_register "${a}"
	done < <(pull_secret_value | jq -r '.auths[]?.auth // empty' 2>/dev/null)
	mirrors_register_secrets
}

ssh_key_value() {
	local v f
	v=$(ic '.sshKey')
	if [[ -n ${v} ]]; then
		printf '%s' "${v}"
		return
	fi
	f=$(ssh_key_file) && cat "${f}"
}

# ssh_keys_all: every SSH public key (sshKey/key file plus
# install.additional_ssh_keys), one per line, without duplicates.
ssh_keys_all() {
	{
		ssh_key_value 2>/dev/null || true
		echo
		cfg '.install.additional_ssh_keys'
	} | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF && !seen[$0]++'
}

ssh_key_file() {
	local f
	for f in "${OKD_PVE_SSH_PUBLIC_KEY_FILE:-}" "$(cfg '.install.ssh_public_key_file')" \
		"${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_ecdsa.pub" "${HOME}/.ssh/id_rsa.pub"; do
		[[ -n ${f} ]] || continue
		f=$(resolve_path "${f}")
		[[ -f ${f} ]] && {
			printf '%s' "${f}"
			return 0
		}
	done
	return 1
}

# resolve_path <path>: expand ~ and make relative paths relative to the
# cluster directory.
resolve_path() {
	local p=$1
	# shellcheck disable=SC2088 # a literal "~/" prefix from the YAML file
	[[ ${p} == "~/"* ]] && p=${HOME}/${p#"~/"}
	[[ ${p} == /* ]] || p=${CLUSTER_DIR}/${p}
	printf '%s' "${p}"
}
