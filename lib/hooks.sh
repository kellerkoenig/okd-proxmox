# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Post-Install hooks: numbered executables and manifests from two sources,
# the generic examples shipped in hooks/ and an external, private hooks
# directory. Both are merged and run in lexical order; on a name collision
# the external directory wins.
#
# Exit codes of a hook: 0 success, 2 warning (continue), anything else
# aborts the run (okd-pve exits with 4).

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_HOOKS_LOADED:-} ]] && return 0
_OKD_PVE_HOOKS_LOADED=1

HOOKS_DIR_OVERRIDE=${HOOKS_DIR_OVERRIDE:-}
HOOK_REPORT=()

builtin_hooks_dir() {
	printf '%s/hooks' "${OKD_PVE_ROOT}"
}

# external_hooks_dir: --hooks-dir > $OKD_PVE_HOOKS_DIR > hooks.dir in cluster.yaml.
external_hooks_dir() {
	local d=${HOOKS_DIR_OVERRIDE:-${OKD_PVE_HOOKS_DIR:-}}
	[[ -n ${d} ]] || d=$(cfg '.hooks.dir')
	[[ -n ${d} ]] || return 0
	d=$(resolve_path "${d}")
	[[ -d ${d} ]] || die "${EXIT_CONFIG}" "Hooks directory ${d} does not exist." "Fix --hooks-dir or hooks.dir in cluster.yaml."
	printf '%s' "${d}"
}

# _hook_entries <dir> <source>: "<name>\t<kind>\t<path>\t<source>" lines.
# kind is "exec" for executable files and "manifest" for manifests/*.yaml.
_hook_entries() {
	local dir=$1 src=$2 f base
	[[ -d ${dir} ]] || return 0
	for f in "${dir}"/*; do
		[[ -f ${f} ]] || continue
		base=${f##*/}
		[[ ${base} =~ ^[0-9]+- ]] || continue
		[[ -x ${f} ]] || continue
		printf '%s\texec\t%s\t%s\n' "${base}" "${f}" "${src}"
	done
	for f in "${dir}"/manifests/*.yaml "${dir}"/manifests/*.yml; do
		[[ -f ${f} ]] || continue
		printf '%s\tmanifest\t%s\t%s\n' "${f##*/}" "${f}" "${src}"
	done
}

# hooks_collect: merged, sorted hook list after applying hooks.builtin /
# hooks.skip. Built-in hooks run only when listed in hooks.builtin (or when
# it is "all"); external hooks always run unless skipped.
hooks_collect() {
	local ext builtin_sel
	ext=$(external_hooks_dir)
	builtin_sel=$(cfg_json '.hooks.builtin')
	{
		_hook_entries "$(builtin_hooks_dir)" builtin
		[[ -n ${ext} ]] && _hook_entries "${ext}" external
	} | jq -R -s -r --argjson sel "${builtin_sel}" --argjson skip "$(cfg_json '.hooks.skip')" '
		def short: sub("\\.(sh|bash|py|yaml|yml)$"; "");
		[split("\n")[] | select(. != "") | split("\t") | {name: .[0], kind: .[1], path: .[2], source: .[3]}]
		| group_by(.name) | map(if length > 1 then (map(select(.source == "external")) | .[0]) else .[0] end)
		| map(.name as $n | ($n | short) as $s | select(
			(.source == "external" or $sel == "all" or (($sel | type) == "array" and ($sel | index($n) or index($s))))
			and ($skip | index($n) or index($s) | not)))
		| sort_by(.name)[] | [.name, .kind, .path, .source] | @tsv'
}

# hook_env: environment exported to every hook.
hook_env_setup() {
	export KUBECONFIG=${KUBECONFIG_FILE}
	export OKD_PVE_CLUSTER_NAME=${CLUSTER_NAME}
	export OKD_PVE_BASE_DOMAIN=${BASE_DOMAIN}
	export OKD_PVE_CLUSTER_DIR=${CLUSTER_DIR}
	OKD_PVE_STORAGE_CLASS=$(monitoring_storage_class)
	export OKD_PVE_STORAGE_CLASS
	OKD_PVE_INFRA_TAINT_KEY=$(cfg '.infra.taint_key')
	OKD_PVE_INFRA_TAINT_VALUE=$(cfg '.infra.taint_value')
	OKD_PVE_INFRA_TAINT_EFFECTS=$(cfg '.infra.taint_effects' | paste -sd' ' -)
	OKD_PVE_INFRA_NODES=$(nodes_query '[.[] | select(.infra) | .name] | join(" ")')
	OKD_PVE_INFRA_NODE_COUNT=$(nodes_query '[.[] | select(.infra)] | length')
	OKD_PVE_INFRA_TAINTED=$(nodes_query 'any(.[]; .taint_infra) | tostring')
	OKD_PVE_OKD_VERSION=$(cfg '.okd.version')
	export OKD_PVE_INFRA_TAINT_KEY OKD_PVE_INFRA_TAINT_VALUE OKD_PVE_INFRA_TAINT_EFFECTS
	export OKD_PVE_INFRA_NODES OKD_PVE_INFRA_NODE_COUNT OKD_PVE_INFRA_TAINTED OKD_PVE_OKD_VERSION
	export OKD_PVE_LIB_DIR=${OKD_PVE_ROOT}/lib
	export OKD_PVE_BIN=${OKD_PVE_ROOT}/okd-pve
	export OKD_PVE_DRY_RUN=${DRY_RUN}
	((DEBUG)) && export OKD_PVE_DEBUG=1
	# hooks.env from cluster.yaml (non-secret settings for the hooks).
	local k v
	while IFS=$'\t' read -r k v; do
		[[ ${k} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
			log_warn "hooks.env: ignoring invalid name ${k}"
			continue
		}
		# Real environment variables win over cluster.yaml.
		[[ -n ${!k+x} ]] && continue
		printf -v "${k}" '%s' "${v}"
		export "${k?}"
	done < <(jq -r '.hooks.env // {} | to_entries[] | "\(.key)\t\(.value | tostring)"' "${CONFIG_JSON}")
	# Secrets for hooks (webhook URLs, tokens, passwords) never appear in
	# output or logs, whether they come from cluster.yaml or the environment.
	local name
	while IFS= read -r name; do
		redact_register "${!name}"
	done < <(compgen -e | grep -E 'WEBHOOK|SECRET|TOKEN|PASSWORD' || true)
}

cmd_hooks_list() {
	local name kind path src last
	{
		echo "HOOK|KIND|SOURCE|LAST RESULT"
		while IFS=$'\t' read -r name kind path src; do
			last=$(state_hook_last "${name}" | awk '{ printf "%s (%ss, %s)", $1, $2, $3 }')
			echo "${name}|${kind}|${src}|${last:--}"
		done < <(hooks_collect)
	} | column -t -s '|'
	local available
	available=$(_hook_entries "$(builtin_hooks_dir)" builtin | cut -f1 | paste -sd' ' -)
	printf '\nBuilt-in hooks run only when listed in hooks.builtin (cluster.yaml). Available: %s\n' "${available}"
}

# hooks_run [--from name | name]: run all hooks, one hook by name (with or
# without number and extension), or every hook from the named one on.
hooks_run() {
	local only='' from='' name kind path src rc start result failed=0 timeout
	if [[ ${1:-} == --from ]]; then
		from=${2:-}
		[[ -n ${from} ]] || die "${EXIT_CONFIG}" "hooks run --from needs a hook name."
	else
		only=${1:-}
	fi
	HOOK_REPORT=()
	timeout=$(cfg '.hooks.timeout')
	local -a list
	mapfile -t list < <(hooks_collect)
	if [[ -n ${only} ]]; then
		mapfile -t list < <(printf '%s\n' "${list[@]}" | awk -F'\t' -v n="${only}" '
			{ s = $1; sub(/\.(sh|bash|py|yaml|yml)$/, "", s); t = s; sub(/^[0-9]+-/, "", t) }
			$1 == n || s == n || t == n')
		((${#list[@]})) || die "${EXIT_CONFIG}" "No hook named ${only}." "See 'okd-pve hooks list' (built-in hooks must be enabled in hooks.builtin)."
	fi
	if [[ -n ${from} ]]; then
		local first
		first=$(printf '%s\n' "${list[@]}" | awk -F'\t' -v n="${from}" '
			{ s = $1; sub(/\.(sh|bash|py|yaml|yml)$/, "", s); t = s; sub(/^[0-9]+-/, "", t) }
			$1 == n || s == n || t == n { print $1; exit }')
		[[ -n ${first} ]] || die "${EXIT_CONFIG}" "No hook named ${from}." "See 'okd-pve hooks list'."
		mapfile -t list < <(printf '%s\n' "${list[@]}" | awk -F'\t' -v f="${first}" '$1 >= f')
	fi
	if ((${#list[@]} == 0)) || [[ -z ${list[0]} ]]; then
		log_info "No Post-Install hooks to run"
		return 0
	fi
	hook_env_setup
	for entry in "${list[@]}"; do
		IFS=$'\t' read -r name kind path src <<<"${entry}"
		if ((DRY_RUN)); then
			dry_run_note "would run hook ${name} (${kind}, ${src}: ${path})"
			continue
		fi
		log_step "Hook ${name} (${src})"
		start=${SECONDS}
		rc=0
		export OKD_PVE_HOOK_NAME=${name}
		if [[ ${kind} == manifest ]]; then
			run_visible '    | ' oc apply -f "${path}" || rc=1
		elif have_cmd timeout; then
			run_visible '    | ' timeout "${timeout}" "${path}" || rc=$?
		else
			run_visible '    | ' "${path}" || rc=$?
		fi
		case ${rc} in
		0) result=ok && log_ok "${name} finished in $(elapsed "${start}")" ;;
		2) result=warning && log_warn "${name} finished with warnings" ;;
		124) result=failed && log_error "${name} timed out after ${timeout}s" ;;
		*) result=failed && log_error "${name} failed (exit ${rc})" ;;
		esac
		state_hook_result "${name}" "${result}" "$((SECONDS - start))"
		HOOK_REPORT+=("${name}|${src}|$(elapsed "${start}")|${result}")
		if [[ ${result} == failed ]]; then
			failed=1
			break
		fi
	done
	((DRY_RUN)) && return 0
	hooks_report "${list[@]}"
	if ((failed)); then
		die "${EXIT_HOOK}" "Hook ${name} failed; remaining hooks were not run." \
			"Fix the cause, then continue with: okd-pve hooks run --from ${name}"
	fi
}

hooks_report() {
	local -A ran=()
	local r name src
	for r in "${HOOK_REPORT[@]}"; do ran[${r%%|*}]=1; done
	printf '\n'
	log_step "Hook report"
	{
		echo "HOOK|SOURCE|DURATION|RESULT"
		printf '%s\n' "${HOOK_REPORT[@]}"
		for r in "$@"; do
			IFS=$'\t' read -r name _ _ src <<<"${r}"
			[[ -n ${ran[${name}]:-} ]] || echo "${name}|${src}|-|not run"
		done
	} | column -t -s '|' | sed 's/^/    /'
	for r in "${HOOK_REPORT[@]}"; do
		[[ ${r##*|} == failed ]] && log_hint "Re-run a failed hook with: okd-pve hooks run ${r%%|*}"
	done
	return 0
}

# hooks_provide_storage_class <name>: a hook manifest defines the class.
hooks_provide_storage_class() {
	local f ext
	ext=$(external_hooks_dir 2>/dev/null || true)
	for f in "$(builtin_hooks_dir)"/manifests/*.y*ml ${ext:+"${ext}"/manifests/*.y*ml}; do
		[[ -f ${f} ]] || continue
		N=$1 yq -e 'select(.kind == "StorageClass" and .metadata.name == strenv(N))' "${f}" >/dev/null 2>&1 && return 0
	done
	return 1
}
