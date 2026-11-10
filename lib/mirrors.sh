# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Registry mirrors: pull-through caches such as Artifactory or Nexus remote
# repositories or Harbor proxy projects (cluster.yaml registry_mirrors).
#
# Pre-Boot (create) renders:
#  - imageDigestSources into the generated install-config.yaml. The agent
#    installer writes them into the live ISO's registries.conf and the
#    cluster's ImageDigestMirrorSet "image-digest-mirror" (release images are
#    pulled by digest), plus exact entries for the OKD release repositories;
#  - an ImageTagMirrorSet "image-tag-mirror" as extra manifest (images
#    pulled by tag: operator catalogs, hook and storage images);
#  - the mirror hosts into proxy.noProxy when a proxy is set;
#  - the mirror credentials (registry_mirrors username/password and
#    auth_file) into the pull secret.
# 'okd-pve mirrors apply' brings a running cluster to the same state.
# 'okd-pve node add' needs nothing extra: oc adm node-image copies the
# cluster's ImageDigestMirrorSets into the node ISO.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_MIRRORS_LOADED:-} ]] && return 0
_OKD_PVE_MIRRORS_LOADED=1

# The name openshift-install gives the ImageDigestMirrorSet it creates from
# imageDigestSources; 'mirrors apply' manages the same object.
MIRRORS_IDMS_NAME=image-digest-mirror
MIRRORS_ITMS_NAME=image-tag-mirror
MIRRORS_ITMS_FILE=99-okd-pve-image-tag-mirror.yaml

# mirrors_json: [{source, mirror, policy}] from cluster.yaml. Without
# fallback the nodes never contact the source (NeverContactSource).
mirrors_json() {
	jq -c '.registry_mirrors as $m | [($m.registries // [])[]
		| {source, mirror,
		   policy: (if (if .fallback == null then $m.fallback else .fallback end)
		            then "AllowContactingSource" else "NeverContactSource" end)}]' "${CONFIG_JSON}"
}

mirrors_enabled() {
	[[ $(mirrors_json) != '[]' ]]
}

# mirrors_hosts: the host (with port) of every mirror, once each.
mirrors_hosts() {
	mirrors_json | jq -r '[.[].mirror | split("/")[0]] | unique[]'
}

# mirrors_auth_file: absolute path of registry_mirrors.auth_file, or nothing.
mirrors_auth_file() {
	local f
	f=$(cfg '.registry_mirrors.auth_file')
	[[ -n ${f} ]] || return 0
	resolve_path "${f}"
}

# jq definitions for the credentials in cluster.yaml (input: the merged
# configuration). The password of an entry comes from the entry, else from
# $OKD_PVE_MIRROR_PASSWORD, else from registry_mirrors.password; the user name
# from the entry, else from registry_mirrors.username. jq reads the
# environment itself, so no secret ever appears on a command line.
_MIRRORS_CRED_JQ='
def mirror_password: env.OKD_PVE_MIRROR_PASSWORD // "" | if . != "" then . else empty end;
def mirror_creds:
  .registry_mirrors as $m
  | ([mirror_password][0] // $m.password // "") as $pw
  | [($m.registries // [])[] | objects
     | {mirror, user: (.username // $m.username // ""), pass: (.password // $pw)}];
def mirror_auths:
  [mirror_creds[] | select(.user != "" and .pass != "")
   | {key: .mirror, value: {auth: ("\(.user):\(.pass)" | @base64)}}] | from_entries;
'

# mirrors_config_auths: {"<mirror>": {auth}} from the user names and
# passwords in cluster.yaml.
mirrors_config_auths() {
	jq -c "${_MIRRORS_CRED_JQ} mirror_auths" "${CONFIG_JSON}"
}

# mirrors_register_secrets: mask the mirror passwords in every output (the
# base64 auth strings are masked with the pull secret).
mirrors_register_secrets() {
	local p
	[[ -z ${OKD_PVE_MIRROR_PASSWORD:-} ]] || redact_register "${OKD_PVE_MIRROR_PASSWORD}"
	while IFS= read -r p; do
		[[ -n ${p} ]] && redact_register "${p}"
	done < <(jq -r "${_MIRRORS_CRED_JQ}"' (.registry_mirrors.password // empty), (mirror_creds[] | .pass | select(. != ""))' "${CONFIG_JSON}" 2>/dev/null)
	return 0
}

# mirrors_config_errors: one error per line for the files and credentials
# registry_mirrors refers to (the rest is checked in lib/jq/validate.jq).
mirrors_config_errors() {
	jq -r "${_MIRRORS_CRED_JQ}"' .registry_mirrors as $m
		| (if ($m.password // "") != "" and ($m.username // "") == "" and ([$m.registries[]? | objects | .username // "" | select(. != "")] | length) == 0
		   then "registry_mirrors.password is set but no username" else empty end),
		  (mirror_creds[] | select(.user != "" and .pass == "")
		   | "registry_mirrors: \(.mirror) has a username but no password (set registry_mirrors.password or OKD_PVE_MIRROR_PASSWORD)"),
		  (mirror_creds[] | select(.user == "" and .pass != "" and ($m.password // "") == "" and ([mirror_password] | length) == 0)
		   | "registry_mirrors: \(.mirror) has a password but no username")' "${CONFIG_JSON}" 2>/dev/null || true
	local f
	f=$(mirrors_auth_file)
	[[ -n ${f} ]] || return 0
	if [[ ! -f ${f} ]]; then
		echo "registry_mirrors.auth_file ${f} does not exist"
	elif ! jq -e '.auths | type == "object"' "${f}" >/dev/null 2>&1; then
		echo "registry_mirrors.auth_file ${f} is not valid JSON with an 'auths' object (podman/docker auth.json format)"
	fi
	return 0
}

# mirrors_has_auth: true when cluster.yaml or auth_file provide credentials.
mirrors_has_auth() {
	[[ -n $(mirrors_auth_file) || $(mirrors_config_auths) != '{}' ]]
}

# mirrors_merge_auth: the pull secret on stdin plus the mirror credentials:
# auth_file, then username/password from cluster.yaml (these win for the
# same mirror).
mirrors_merge_auth() {
	local f
	f=$(mirrors_auth_file)
	[[ -n ${f} && -f ${f} ]] || f=/dev/null
	jq -c --slurpfile a "${f}" --slurpfile c "${CONFIG_JSON}" "${_MIRRORS_CRED_JQ}"'
		.auths = ((.auths // {}) + ($a[0].auths // {}) + ($c[0] | mirror_auths))'
}

# The OKD release image and its payload. openshift-install only recognizes a
# mirror for the release image when a source names its repository exactly
# (otherwise it warns and does not pass a release mirror to the agent), so
# mirrors_digest_sources adds these repositories to a mirror that covers them.
MIRRORS_RELEASE_REPOS=("${OKD_RELEASE_IMAGE_REPO}" quay.io/okd/scos-content)

# mirrors_digest_sources: imageDigestSources for install-config.yaml: the
# entries already in install-config.yaml, then the configured mirrors, then
# an exact entry for every release repository a configured mirror covers
# (e.g. quay.io -> quay-cache.example.com also gives quay.io/okd/scos-release
# -> quay-cache.example.com/okd/scos-release).
mirrors_digest_sources() {
	jq -c --argjson m "$(mirrors_json)" --argjson repos "$(printf '%s\n' "${MIRRORS_RELEASE_REPOS[@]}" | jq -R . | jq -sc .)" '
		((.imageDigestSources // []) + [$m[] | {source, mirrors: [.mirror], sourcePolicy: .policy}]) as $ids
		| $ids + [$repos[] as $repo
			| select(all($ids[]; .source != $repo))
			| [$m[] | select(.source as $s | $s == $repo or ($repo | startswith($s + "/")))]
			| sort_by(.source | length) | last // empty
			| . as $e | {source: $repo, mirrors: [$e.mirror + ($repo | ltrimstr($e.source))], sourcePolicy: $e.policy}]' "${INSTALL_CONFIG_JSON}"
}

# mirrors_idms_yaml: the ImageDigestMirrorSet openshift-install creates from
# mirrors_digest_sources, for a running cluster.
mirrors_idms_yaml() {
	mirrors_digest_sources | jq --arg name "${MIRRORS_IDMS_NAME}" '{
		apiVersion: "config.openshift.io/v1",
		kind: "ImageDigestMirrorSet",
		metadata: {name: $name},
		spec: {imageDigestMirrors: [.[] | {source, mirrors}
			+ (if .sourcePolicy then {mirrorSourcePolicy: .sourcePolicy} else {} end)]}
	}' | yq -P '.'
}

# mirrors_itms_yaml: ImageTagMirrorSet for images pulled by tag.
mirrors_itms_yaml() {
	mirrors_json | jq --arg name "${MIRRORS_ITMS_NAME}" '{
		apiVersion: "config.openshift.io/v1",
		kind: "ImageTagMirrorSet",
		metadata: {name: $name, labels: {"app.kubernetes.io/managed-by": "okd-pve"}},
		spec: {imageTagMirrors: [.[] | {source, mirrors: [.mirror], mirrorSourcePolicy: .policy}]}
	}' | yq -P '.'
}

# no_proxy_covers <host[:port]> <no-proxy-list>: true when an entry of the
# comma separated list matches the host the way Go (CRI-O, kubelet) and curl
# match it: "*", the name itself, or a parent domain with or without a
# leading "." or "*.".
no_proxy_covers() {
	local host=${1%%:*} e
	local -a entries
	IFS=, read -ra entries <<<"$2"
	for e in "${entries[@]+"${entries[@]}"}"; do
		e=${e//[[:space:]]/}
		[[ ${e} == '*' ]] && return 0
		e=${e#\*}
		e=${e#.}
		[[ -n ${e} ]] || continue
		[[ ${host} == "${e}" || ${host} == *".${e}" ]] && return 0
	done
	return 1
}

# mirrors_no_proxy <no-proxy-list>: the list plus every mirror host it does
# not cover yet.
mirrors_no_proxy() {
	local list=$1 h
	while IFS= read -r h; do
		[[ -n ${h} ]] || continue
		no_proxy_covers "${h}" "${list}" || list=${list:+${list},}${h%%:*}
	done < <(mirrors_hosts)
	printf '%s' "${list}"
}

# mirrors_render_install_config <file>: add imageDigestSources and the
# mirror hosts in proxy.noProxy to a rendered install-config.yaml.
mirrors_render_install_config() {
	local f=$1
	mirrors_enabled || return 0
	IDS=$(mirrors_digest_sources) yq -i '.imageDigestSources = (strenv(IDS) | from_json) | (.imageDigestSources | ...) style=""' "${f}"
	if [[ -n $(ic '.proxy.httpProxy') || -n $(ic '.proxy.httpsProxy') ]]; then
		NP=$(mirrors_no_proxy "$(ic '.proxy.noProxy')") yq -i '.proxy.noProxy = strenv(NP)' "${f}"
	fi
}

# mirror_auth_for <host>: the base64 user:password for host from the pull
# secret (exact host, or the longest "host/path" entry).
mirror_auth_for() {
	pull_secret_value | jq -r --arg h "$1" '(.auths // {}) | to_entries
		| map(select(.key == $h or (.key | startswith($h + "/")))) | sort_by(.key | length) | .[0].value.auth // empty'
}

# registry_probe <host> [auth]: HTTP status of GET https://<host>/v2/
# ("000" = no answer). The credentials reach curl on stdin, never as an
# argument.
registry_probe() {
	local host=$1 auth=${2:-}
	{ [[ -z ${auth} ]] || printf 'header = "Authorization: Basic %s"\n' "${auth}"; } |
		curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 -K - "https://${host}/v2/" 2>/dev/null || true
}

# registry_token_probe <host> <auth>: HTTP status of the token endpoint the
# registry announces (Bearer realm), requested with the credentials. For
# registries that do not accept Basic auth on /v2/ (Harbor, Quay).
registry_token_probe() {
	local host=$1 auth=$2 hdr realm service
	hdr=$(curl -sS -o /dev/null -D - --connect-timeout 10 --max-time 30 "https://${host}/v2/" 2>/dev/null |
		grep -i '^www-authenticate: *bearer' | head -n 1 | tr -d '\r') || true
	realm=$(sed -nE 's/.*realm="([^"]*)".*/\1/p' <<<"${hdr}")
	service=$(sed -nE 's/.*service="([^"]*)".*/\1/p' <<<"${hdr}")
	[[ -n ${realm} ]] || {
		echo 000
		return 0
	}
	printf 'header = "Authorization: Basic %s"\n' "${auth}" |
		curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 -K - -G \
			${service:+--data-urlencode "service=${service}"} "${realm}" 2>/dev/null || true
}

# pf_mirrors: reachability and credentials of every mirror host, checked
# from this workstation (openshift-install pulls the release through the
# mirrors here, the nodes pull through them later).
pf_mirrors() {
	local host strict code auth sev
	if [[ $(mirrors_json | jq '[.[] | select(.policy == "NeverContactSource")] | length') -gt 0 ]]; then
		pf INFO "Sources with fallback: false are pulled only from their mirror; the mirror must have every image"
	fi
	while IFS= read -r host; do
		strict=$(mirrors_json | jq -r --arg h "${host}" \
			'any(.[]; (.mirror | split("/")[0]) == $h and .policy == "NeverContactSource")')
		sev=WARN
		[[ ${strict} == true ]] && sev=FAIL
		code=$(registry_probe "${host}")
		case ${code} in
		200)
			pf PASS "Mirror ${host} answers (anonymous access)"
			continue
			;;
		401) ;;
		000)
			pf "${sev}" "Mirror ${host} does not answer (https://${host}/v2/)" \
				"Check DNS, firewall and the proxy settings of this workstation; the nodes need the same access."
			continue
			;;
		*)
			pf "${sev}" "Mirror ${host} answers HTTP ${code} on /v2/ instead of 200 or 401" \
				"Does the repository exist, and is this its Docker registry host (e.g. <repo-key>.<artifactory-host> with subdomain access)?"
			continue
			;;
		esac
		auth=$(mirror_auth_for "${host}")
		if [[ -z ${auth} ]]; then
			pf "${sev}" "Mirror ${host} needs credentials, but the pull secret has none for it" \
				"Set registry_mirrors.username and password (or OKD_PVE_MIRROR_PASSWORD), or: podman login --authfile <registry_mirrors.auth_file> ${host}"
			continue
		fi
		redact_register "${auth}"
		code=$(registry_probe "${host}" "${auth}")
		[[ ${code} == 200 ]] || code=$(registry_token_probe "${host}" "${auth}")
		if [[ ${code} == 200 ]]; then
			pf PASS "Mirror ${host} accepts the credentials from the pull secret"
		else
			pf "${sev}" "Mirror ${host} rejects the credentials from the pull secret (HTTP ${code})" \
				"Check registry_mirrors.username/password (or OKD_PVE_MIRROR_PASSWORD), or log in again: podman login --authfile <registry_mirrors.auth_file> ${host}"
		fi
	done < <(mirrors_hosts)
	local f
	f=$(mirrors_auth_file)
	if [[ -n ${f} && -f ${f} ]] && (((8#$(file_mode "${f}") & 8#077) != 0)); then
		pf WARN "${f} is readable by group/others (mode $(file_mode "${f}"))" "chmod 600 ${f}"
	fi
	if [[ -n $(jq -r '[.registry_mirrors.password // empty, (.registry_mirrors.registries[]? | objects | .password // empty)] | first // empty' "${CONFIG_JSON}") ]] &&
		(((8#$(file_mode "${CONFIG_FILE}") & 8#077) != 0)); then
		pf WARN "${CONFIG_FILE} holds a mirror password and is readable by group/others (mode $(file_mode "${CONFIG_FILE}"))" \
			"chmod 600 ${CONFIG_FILE}, or pass the password as OKD_PVE_MIRROR_PASSWORD"
	fi
}

# ---------------------------------------------------------------------------
# mirrors apply: the same configuration on a running cluster
# ---------------------------------------------------------------------------

# _mirrors_live_spec <kind> <name>: .spec of a live object, "null" if absent.
_mirrors_live_spec() {
	local out
	out=$(oc get "$1" "$2" -o json --ignore-not-found) || die "${EXIT_ERROR}" "Cannot read $1/$2." "Check the API (okd-pve verify)."
	[[ -n ${out} ]] || {
		echo null
		return 0
	}
	jq -cS '.spec' <<<"${out}"
}

# _mirrors_sync <kind> <name> <yaml>: create, update or (empty yaml) delete
# one object; returns 0 when it changed something.
_mirrors_sync() {
	local kind=$1 name=$2 yaml=$3 live want
	live=$(_mirrors_live_spec "${kind}" "${name}")
	if [[ -z ${yaml} ]]; then
		[[ ${live} != null ]] || return 1
		if ((DRY_RUN)); then
			dry_run_note "would delete ${kind}/${name}"
		else
			run_logged oc delete "${kind}" "${name}" --ignore-not-found
			log_info "${kind}/${name} deleted"
		fi
		return 0
	fi
	want=$(yq -o json -I0 '.spec' <<<"${yaml}" | jq -cS .)
	[[ ${live} != "${want}" ]] || {
		log_info "${kind}/${name} is up to date"
		return 1
	}
	if ((DRY_RUN)); then
		dry_run_note "would apply ${kind}/${name}:"
		local line
		while IFS= read -r line; do printf '      %s\n' "${line}"; done <<<"${yaml}"
	else
		oc apply -f - <<<"${yaml}" >/dev/null
		log_info "${kind}/${name} applied"
	fi
	return 0
}

# _mirrors_sync_pull_secret: add the mirror credentials to the cluster's
# global pull secret; returns 0 when it changed it.
_mirrors_sync_pull_secret() {
	local live merged tmp
	mirrors_has_auth || return 1
	live=$(oc get secret pull-secret -n openshift-config -o json | jq -r '.data[".dockerconfigjson"]' | base64 -d) ||
		die "${EXIT_ERROR}" "Cannot read the cluster pull secret (openshift-config/pull-secret)."
	merged=$(mirrors_merge_auth <<<"${live}")
	if [[ $(jq -cS . <<<"${live}") == "$(jq -cS . <<<"${merged}")" ]]; then
		log_info "Cluster pull secret already has the mirror credentials"
		return 1
	fi
	if ((DRY_RUN)); then
		dry_run_note "would add the credentials for $(printf '%s\n%s\n' "${live}" "${merged}" |
			jq -rs '.[0].auths as $l | .[1].auths | to_entries | map(select($l[.key] != .value) | .key) | join(" ")') to openshift-config/pull-secret"
		return 0
	fi
	tmp=$(mktemp "${OKD_PVE_TMP}/pull-secret.XXXXXX")
	chmod 600 "${tmp}"
	printf '%s' "${merged}" >"${tmp}"
	run_logged oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${tmp}"
	rm -f "${tmp}"
	log_info "Mirror credentials added to openshift-config/pull-secret"
	return 0
}

# _mirrors_check_proxy: warn about mirror hosts the cluster reaches through
# its proxy. Changing proxy/cluster reboots every node, so this is left to
# the user.
_mirrors_check_proxy() {
	local proxy no_proxy h
	local -a missing=()
	proxy=$(oc get proxy cluster -o json 2>/dev/null) || return 0
	[[ -n $(jq -r '.spec.httpProxy // .spec.httpsProxy // empty' <<<"${proxy}") ]] || return 0
	no_proxy=$(jq -r '.status.noProxy // .spec.noProxy // ""' <<<"${proxy}")
	while IFS= read -r h; do
		no_proxy_covers "${h}" "${no_proxy}" || missing+=("${h%%:*}")
	done < <(mirrors_hosts)
	((${#missing[@]})) || return 0
	log_warn "The cluster reaches ${missing[*]} through its proxy (not in noProxy)."
	log_hint "Fine if the proxy can reach the mirror. Otherwise add the host(s) to spec.noProxy of proxy/cluster yourself: the MCO then reboots every node. A rebuild adds them automatically."
}

cmd_mirrors_apply() {
	[[ $# -eq 0 ]] || die "${EXIT_CONFIG}" "mirrors apply takes no arguments." "okd-pve mirrors apply"
	cluster_api_init
	log_step "Registry mirrors: checking from this workstation"
	if mirrors_enabled; then
		PF_PASS=0 PF_WARN=0 PF_FAIL=0
		pf_mirrors
		((PF_FAIL == 0)) || die "${EXIT_PREFLIGHT}" "A mirror without fallback is not usable." \
			"Fix the items above first: without fallback the nodes could not pull any image of that source."
	else
		log_info "registry_mirrors.registries is empty: removing the mirror configuration okd-pve manages"
	fi

	log_step "Registry mirrors: applying to the cluster"
	local changed=0 idms='' itms=''
	_mirrors_sync_pull_secret && changed=1
	[[ $(mirrors_digest_sources) == '[]' ]] || idms=$(mirrors_idms_yaml)
	mirrors_enabled && itms=$(mirrors_itms_yaml)
	_mirrors_sync imagedigestmirrorset "${MIRRORS_IDMS_NAME}" "${idms}" && changed=1
	_mirrors_sync imagetagmirrorset "${MIRRORS_ITMS_NAME}" "${itms}" && changed=1
	mirrors_enabled && _mirrors_check_proxy

	if ((! changed)); then
		log_ok "Registry mirrors are up to date"
		return 0
	fi
	((DRY_RUN)) && return 0
	# The MCO rolls registries.conf and the pull secret out node by node and
	# reloads CRI-O, never reboots. New tag mirrors (and removed or blocked
	# entries) make it drain each node first; digest mirrors and the pull
	# secret do not. Give it a moment to start.
	log_info "Waiting for the MachineConfigPools (no reboot; new tag mirrors make the MCO drain the nodes one at a time)"
	sleep "${OKD_PVE_MCP_SETTLE:-30}"
	local pool
	while IFS= read -r pool; do
		[[ -n ${pool} ]] || continue
		wait_for_mcp "${pool}" 3600 || die "${EXIT_ERROR}" "MachineConfigPool ${pool} did not finish the update." "oc get mcp; oc describe mcp ${pool}"
	done < <(oc get machineconfigpool -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
	log_ok "Registry mirrors applied"
}
