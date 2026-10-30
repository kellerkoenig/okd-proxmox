#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Fails when the repository contains data that looks environment specific:
# IPv4 addresses outside the documentation ranges, domain names that are not
# placeholders or well-known public services, webhook URLs, API tokens.
#
# Allowed exceptions: one extended regular expression per line in
# .leakcheck-allow, matched against the finding.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${root}"

mapfile -t files < <(
	if git rev-parse --git-dir >/dev/null 2>&1; then
		git ls-files --cached --others --exclude-standard
	else
		find . -type f -not -path './.git/*' -not -path './.tools/*' | sed 's|^\./||'
	fi | grep -vxE 'LICENSE|LICENSES/.*|\.leakcheck-allow' | sort -u
)

allow=()
if [[ -f .leakcheck-allow ]]; then
	while IFS= read -r line; do
		[[ -z ${line} || ${line} == \#* ]] && continue
		allow+=("${line}")
	done <.leakcheck-allow
fi

allowed() {
	local a
	for a in "${allow[@]}"; do
		[[ $1 =~ ^(${a})$ ]] && return 0
	done
	return 1
}

findings=0
report() {
	printf '%s:%s: %s (%s)\n' "$1" "$2" "$3" "$4"
	findings=$((findings + 1))
}

# scan <label> <grep-ERE> [check-allow]
scan() {
	local label=$1 re=$2 check=${3:-yes} hit file line value
	while IFS= read -r hit; do
		file=${hit%%:*}
		hit=${hit#*:}
		line=${hit%%:*}
		value=${hit#*:}
		if [[ ${check} == yes ]] && allowed "${value}"; then
			continue
		fi
		report "${file}" "${line}" "${value}" "${label}"
	done < <(grep -HnoE "${re}" "${files[@]}" 2>/dev/null || true)
}

scan "IPv4 address" '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
scan "domain name" '\b([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+(com|net|org|de|eu|at|ch|nl|fr|uk|io|dev|cloud|local|lan|intra|intranet|internal|corp|home|group|biz)\b'
scan "webhook URL" '(hooks\.slack\.com|webhook\.office\.com|outlook\.office(365)?\.com/webhook|discord(app)?\.com/api/webhooks|chat\.googleapis\.com)[^[:space:]"]*' no
scan "API token" '[A-Za-z0-9._-]+@[a-z]+![A-Za-z0-9_-]+=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
scan "UUID" '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

if ((findings)); then
	printf '\n%d finding(s). Replace real data with placeholders (example.com, RFC 5737 addresses)\n' "${findings}" >&2
	printf 'or, if the value is public and intended, add a pattern to .leakcheck-allow.\n' >&2
	exit 1
fi
echo "No environment-specific data found in ${#files[@]} files."
