# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Pre-Boot manifests: rendered from templates/preboot with values from
# cluster.yaml plus the user's own <cluster>/preboot directory. The result
# goes to <install-dir>/openshift/, where the agent-based installer picks it
# up and bakes it into the Ignition configs ("extra manifests").
#
# Rule of thumb: everything that produces a MachineConfig or KubeletConfig
# belongs here. Applied after installation each of them triggers a rolling
# reboot of all nodes in the affected pool.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_MANIFESTS_LOADED:-} ]] && return 0
_OKD_PVE_MANIFESTS_LOADED=1

declare -gA TPL=()

# render_template <file>: replace {{KEY}} with ${TPL[KEY]}. A placeholder on
# a line of its own takes a multi-line value; every value line gets the
# placeholder's indentation. Unknown placeholders are an error.
render_template() {
	local line key val indent
	local re_block='^([[:space:]]*)\{\{([A-Z0-9_]+)\}\}[[:space:]]*$' re_inline='\{\{([A-Z0-9_]+)\}\}'
	while IFS= read -r line || [[ -n ${line} ]]; do
		if [[ ${line} =~ ${re_block} ]]; then
			indent=${BASH_REMATCH[1]} key=${BASH_REMATCH[2]}
			[[ -v TPL[${key}] ]] || { echo "${1##*/}: no value for {{${key}}}" >&2 && return 1; }
			[[ -n ${TPL[${key}]} ]] || continue
			while IFS= read -r val; do
				printf '%s%s\n' "${indent}" "${val}"
			done <<<"${TPL[${key}]}"
			continue
		fi
		while [[ ${line} =~ ${re_inline} ]]; do
			key=${BASH_REMATCH[1]}
			[[ -v TPL[${key}] ]] || { echo "${1##*/}: no value for {{${key}}}" >&2 && return 1; }
			line=${line//"{{${key}}}"/${TPL[${key}]}}
		done
		printf '%s\n' "${line}"
	done <"$1"
}

# yaml_map_lines <jq-path>: "key: value" lines of a map in cluster.yaml.
yaml_map_lines() {
	jq -r "$1 | to_entries[] | \"\\(.key | tojson): \\(.value | tostring | tojson)\"" "${CONFIG_JSON}"
}

_preboot_tpl() {
	printf '%s/templates/preboot/%s' "${OKD_PVE_ROOT}" "$1"
}

# _butane <in.bu> <out.yaml> [files-dir]
_butane() {
	local files_dir=${3:-$(dirname "$1")} err
	if ! err=$("${BUTANE:-butane}" --strict --files-dir "${files_dir}" "$1" 2>&1 >"$2"); then
		echo "butane failed for ${1##*/}: ${err}" >&2
		return 1
	fi
}

# _chrony_servers <role>: effective NTP servers for a pool.
_chrony_servers() {
	local -a s
	mapfile -t s < <(cfg ".preboot.chrony_overrides.$1")
	((${#s[@]})) || mapfile -t s < <(cfg '.network.ntp_servers')
	printf '%s\n' "${s[@]}"
}

_render_chrony() {
	local role=$1 name=$2 out=$3 work=$4 s lines=''
	while IFS= read -r s; do
		[[ -n ${s} ]] && lines+="server ${s} iburst"$'\n'
	done < <(_chrony_servers "${role}")
	TPL=([ROLE]=${role} [NAME]=${name} [BUTANE_SPEC]=${BUTANE_OPENSHIFT_SPEC} [SERVER_LINES]=${lines%$'\n'})
	render_template "$(_preboot_tpl chrony.bu.tpl)" >"${work}/${name}.bu" || return 1
	_butane "${work}/${name}.bu" "${out}/${name}.yaml"
}

_render_kubelet() {
	local pool=$1 out=$2 grace='' key
	while IFS= read -r key; do
		grace+="${key}: \"$(cfg '.kubelet.eviction_soft_grace_period')\""$'\n'
	done < <(jq -r '.kubelet.eviction_soft | keys[] | tojson' "${CONFIG_JSON}")
	TPL=(
		[POOL]=${pool}
		[AUTO_SIZING]=$(jq -r '.kubelet.auto_sizing_reserved' "${CONFIG_JSON}")
		[GC_HIGH]=$(cfg '.kubelet.image_gc_high_threshold_percent')
		[GC_LOW]=$(cfg '.kubelet.image_gc_low_threshold_percent')
		[GC_MIN_AGE]=$(cfg '.kubelet.image_minimum_gc_age')
		[EVICTION_TRANSITION]=$(cfg '.kubelet.eviction_pressure_transition_period')
		[EVICTION_HARD]=$(yaml_map_lines '.kubelet.eviction_hard')
		[EVICTION_SOFT]=$(yaml_map_lines '.kubelet.eviction_soft')
		[EVICTION_SOFT_GRACE]=${grace%$'\n'}
	)
	render_template "$(_preboot_tpl kubelet-config.yaml.tpl)" >"${out}/99-okd-pve-kubelet-${pool}.yaml"
}

_render_kargs() {
	local role=$1 name=$2 out=$3 a lines=''
	while IFS= read -r a; do
		[[ -n ${a} ]] && lines+="- $(jq -rn --arg a "${a}" '$a | tojson')"$'\n'
	done < <(cfg ".preboot.kernel_args.${role}")
	[[ -n ${lines} ]] || return 0
	TPL=([ROLE]=${role} [NAME]=${name} [KARGS]=${lines%$'\n'})
	render_template "$(_preboot_tpl kernel-args.yaml.tpl)" >"${out}/${name}.yaml"
}

# _render_ssh_keys <role> <name> <out>: all keys except the first one.
_render_ssh_keys() {
	local role=$1 name=$2 out=$3 k lines=''
	while IFS= read -r k; do
		lines+="- $(jq -rn --arg k "${k}" '$k | tojson')"$'\n'
	done < <(ssh_keys_all | tail -n +2)
	[[ -n ${lines} ]] || return 0
	TPL=([ROLE]=${role} [NAME]=${name} [KEYS]=${lines%$'\n'})
	render_template "$(_preboot_tpl ssh-keys.yaml.tpl)" >"${out}/${name}.yaml"
}

_render_ca() {
	local role=$1 name=$2 out=$3 work=$4 ca
	ca=$(resolve_path "$(cfg '.preboot.ca_bundle_file')")
	[[ -f ${ca} ]] || { echo "preboot.ca_bundle_file ${ca} does not exist" >&2 && return 1; }
	cp "${ca}" "${work}/okd-pve-extra-ca.crt"
	TPL=([ROLE]=${role} [NAME]=${name} [BUTANE_SPEC]=${BUTANE_OPENSHIFT_SPEC} [CA_FILE]=okd-pve-extra-ca.crt)
	render_template "$(_preboot_tpl ca-bundle.bu.tpl)" >"${work}/${name}.bu" || return 1
	_butane "${work}/${name}.bu" "${out}/${name}.yaml" "${work}"
}

# manifests_render <out-dir>: render all Pre-Boot manifests into out-dir.
manifests_render() {
	local out=$1 work role pool
	mkdir -p "${out}"
	work=$(mktemp -d "${OKD_PVE_TMP}/preboot-work.XXXXXX")
	local infra_pool=0
	infra_pool_enabled && infra_pool=1

	if ((infra_pool)); then
		TPL=()
		render_template "$(_preboot_tpl infra-mcp.yaml.tpl)" >"${out}/99-okd-pve-infra-machineconfigpool.yaml" || return 1
	fi

	if [[ $(jq -r '.preboot.chrony' "${CONFIG_JSON}") == true ]]; then
		for role in master worker; do
			_render_chrony "${role}" "99-${role}-okd-pve-chrony" "${out}" "${work}" || return 1
		done
		# Infra override: named to sort after the worker MachineConfig so it wins
		# the merge (MachineConfigs are merged in name order, later wins).
		if ((infra_pool)) && [[ -n $(cfg '.preboot.chrony_overrides.infra') ]] &&
			[[ $(_chrony_servers infra) != "$(_chrony_servers worker)" ]]; then
			_render_chrony infra "99-zz-infra-okd-pve-chrony" "${out}" "${work}" || return 1
		fi
	fi

	if [[ $(jq -r '.preboot.kubelet' "${CONFIG_JSON}") == true ]]; then
		for pool in $(cfg '.kubelet.pools'); do
			case ${pool} in
			master | worker) _render_kubelet "${pool}" "${out}" || return 1 ;;
			*) echo "kubelet.pools: '${pool}' is not supported (only master and worker; a dedicated infra pool inherits the worker config)" >&2 && return 1 ;;
			esac
		done
	fi

	for role in master worker; do
		_render_kargs "${role}" "99-${role}-okd-pve-kargs" "${out}" || return 1
	done
	((infra_pool)) && { _render_kargs infra "99-infra-okd-pve-kargs" "${out}" || return 1; }

	for role in master worker; do
		_render_ssh_keys "${role}" "99-${role}-okd-pve-ssh" "${out}" || return 1
	done

	if [[ -n $(cfg '.preboot.ca_bundle_file') ]]; then
		for role in master worker; do
			_render_ca "${role}" "99-${role}-okd-pve-ca" "${out}" "${work}" || return 1
		done
	fi

	_manifests_user "${out}" || return 1
	_manifests_validate "${out}"
}

# _manifests_user <out>: copy/convert <cluster>/preboot. Butane files (.bu)
# are rendered; YAML is copied unchanged. A user file with the same output
# name as a built-in manifest replaces it.
_manifests_user() {
	local out=$1 f base
	[[ -d ${PREBOOT_USER_DIR} ]] || return 0
	while IFS= read -r -d '' f; do
		base=${f##*/}
		case ${base} in
		*.bu)
			_butane "${f}" "${out}/${base%.bu}.yaml" "${PREBOOT_USER_DIR}" || return 1
			;;
		*.yaml | *.yml)
			cp "${f}" "${out}/${base}"
			;;
		README* | .*) ;;
		*)
			echo "Ignoring ${f}: Pre-Boot manifests must be .yaml, .yml or .bu" >&2
			;;
		esac
	done < <(find "${PREBOOT_USER_DIR}" -maxdepth 1 -type f -print0 | sort -z)
}

# _manifests_validate <dir>: every file must be parseable YAML with
# apiVersion, kind and metadata.name.
_manifests_validate() {
	local f doc rc=0
	for f in "$1"/*; do
		[[ -f ${f} ]] || continue
		if ! doc=$(yq -o json -I0 '.' "${f}" 2>&1); then
			echo "${f##*/}: invalid YAML: ${doc}" >&2
			rc=1
			continue
		fi
		if ! yq -e 'select(document_index == 0) | .apiVersion and .kind and .metadata.name' "${f}" >/dev/null 2>&1; then
			echo "${f##*/}: apiVersion, kind and metadata.name are required" >&2
			rc=1
		fi
		if yq -e 'select(.kind == "MachineConfig") | .metadata.labels."machineconfiguration.openshift.io/role" == null' "${f}" >/dev/null 2>&1; then
			echo "${f##*/}: MachineConfig without machineconfiguration.openshift.io/role label" >&2
			rc=1
		fi
	done
	return "${rc}"
}
