# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Logging, error handling, traps, colors, secret redaction and small helpers
# shared by every other library.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_COMMON_LOADED:-} ]] && return 0
_OKD_PVE_COMMON_LOADED=1

# Exit codes (documented in README.md).
EXIT_OK=0
EXIT_ERROR=1
EXIT_CONFIG=2
EXIT_PREFLIGHT=3
EXIT_HOOK=4
EXIT_INTERRUPTED=130

# Global flags, set by the CLI parser.
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
DEBUG=${DEBUG:-0}
NO_COLOR=${NO_COLOR:-}
LOG_FILE=${LOG_FILE:-}

# Values that must never appear in any output. Register with redact_register.
REDACT_VALUES=()
REDACT_MARK='***REDACTED***'

# Private scratch directory, removed on exit.
OKD_PVE_TMP=${OKD_PVE_TMP:-}

C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''

setup_colors() {
	if [[ -z ${NO_COLOR} && -t 1 && ${TERM:-dumb} != dumb ]]; then
		C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
		C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
	else
		C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
	fi
}

# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------

# redact_register <value>...: never print these values anywhere. Values
# shorter than 4 characters are ignored to avoid shredding unrelated output.
redact_register() {
	local v
	for v in "$@"; do
		[[ ${#v} -ge 4 ]] || continue
		REDACT_VALUES+=("$v")
	done
}

# redact_string <text>: print text with all registered secrets and well-known
# credential patterns masked.
redact_string() {
	local s=$1 v
	for v in "${REDACT_VALUES[@]+"${REDACT_VALUES[@]}"}"; do
		s=${s//"$v"/$REDACT_MARK}
	done
	local re='(PVEAPIToken=|[Aa]uthorization: *[Bb]earer +)([^[:space:]"'"'"']+)' out=''
	while [[ $s =~ $re ]]; do
		out+=${s%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}${REDACT_MARK}
		s=${s#*"${BASH_REMATCH[0]}"}
	done
	printf '%s\n' "${out}${s}"
}

# redact_stream [--log FILE] [--copy FILE] [--echo PREFIX]: filter stdin.
# Writes the redacted stream to the log file and/or a copy file and/or
# stdout (each line prefixed). Ignores SIGINT so that a Ctrl-C reaches the
# producing command (for example tofu) and lets it shut down cleanly instead
# of killing it with SIGPIPE.
redact_stream() {
	{ set +x; } 2>/dev/null
	local log=/dev/null copy=/dev/null echo_prefix='' do_echo=0
	while (($#)); do
		case $1 in
		--log) log=${2:-/dev/null} && shift 2 ;;
		--copy) copy=$2 && shift 2 ;;
		--echo) echo_prefix=$2 do_echo=1 && shift 2 ;;
		*) return 2 ;;
		esac
	done
	[[ -n $log ]] || log=/dev/null
	local list=''
	if ((${#REDACT_VALUES[@]})); then
		list=$(printf '%s\n' "${REDACT_VALUES[@]}" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
	fi
	(
		trap '' INT
		OKD_PVE_REDACT_LIST=$list awk -v logf="${log}" -v copy="${copy}" -v pfx="${echo_prefix}" \
			-v do_echo="$do_echo" -v mark="$REDACT_MARK" '
			BEGIN { n = split(ENVIRON["OKD_PVE_REDACT_LIST"], secrets, "\n") }
			{
				line = $0
				for (i = 1; i <= n; i++) {
					s = secrets[i]
					if (s == "") continue
					out = ""
					while ((p = index(line, s)) > 0) {
						out = out substr(line, 1, p - 1) mark
						line = substr(line, p + length(s))
					}
					line = out line
				}
				gsub(/PVEAPIToken=[^ \t"'"'"']+/, "PVEAPIToken=" mark, line)
				gsub(/[Aa]uthorization: *[Bb]earer +[^ \t"'"'"']+/, "Authorization: Bearer " mark, line)
				if (logf != "/dev/null") { print line >> logf; fflush(logf) }
				if (copy != "/dev/null") { print line >> copy; fflush(copy) }
				if (do_echo == 1) { print pfx line; fflush() }
			}'
	)
}

# redact: plain stdin -> stdout filter.
redact() {
	redact_stream --echo ''
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log_to_file() {
	[[ -n ${LOG_FILE} ]] || return 0
	local ts
	printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
	redact_string "${ts} [$1] $2" >>"${LOG_FILE}" 2>/dev/null || true
}

log_step() {
	_log_to_file STEP "$*"
	printf '%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$(redact_string "$*")" "${C_RESET}"
}

log_info() {
	_log_to_file INFO "$*"
	printf '    %s\n' "$(redact_string "$*")"
}

log_ok() {
	_log_to_file OK "$*"
	printf '    %sOK%s  %s\n' "${C_GREEN}" "${C_RESET}" "$(redact_string "$*")"
}

log_warn() {
	_log_to_file WARN "$*"
	printf '    %sWARN%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(redact_string "$*")" >&2
}

log_error() {
	_log_to_file ERROR "$*"
	printf '%sERROR:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$(redact_string "$*")" >&2
}

log_hint() {
	_log_to_file HINT "$*"
	printf '       %s%s%s\n' "${C_DIM}" "$(redact_string "$*")" "${C_RESET}" >&2
}

log_debug() {
	_log_to_file DEBUG "$*"
	((DEBUG)) || return 0
	printf '%s    debug: %s%s\n' "${C_DIM}" "$(redact_string "$*")" "${C_RESET}" >&2
}

# log_raw: write to the log file only (command output, tables, ...).
log_raw() {
	_log_to_file RAW "$*"
}

# die <exit-code> <message> [next-step hint]
die() {
	local code=$1 msg=$2 hint=${3:-}
	log_error "${msg}"
	[[ -n ${hint} ]] && log_hint "Next step: ${hint}"
	if [[ -n ${LOG_FILE} && -f ${LOG_FILE} ]]; then
		log_hint "Full log: ${LOG_FILE}"
	fi
	exit "${code}"
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

# run_logged <cmd...>: run a command, send its complete (redacted) output to
# the log file and show the last lines on failure. Returns the exit code.
run_logged() {
	local copy rc=0
	copy=$(mktemp "${OKD_PVE_TMP:-/tmp}/run.XXXXXX")
	_log_to_file EXEC "$*"
	set +e
	"$@" 2>&1 | redact_stream --log "${LOG_FILE}" --copy "${copy}"
	rc=${PIPESTATUS[0]}
	set -e
	if ((rc != 0)); then
		log_error "Command failed (exit ${rc}): $1"
		tail -n 15 "${copy}" | sed 's/^/       | /' >&2
	fi
	rm -f "${copy}"
	return "${rc}"
}

# run_visible <prefix> <cmd...>: like run_logged, but also stream the
# redacted output to stdout with the given prefix.
run_visible() {
	local prefix=$1 rc=0
	shift
	_log_to_file EXEC "$*"
	set +e
	"$@" 2>&1 | redact_stream --log "${LOG_FILE}" --echo "${prefix}"
	rc=${PIPESTATUS[0]}
	set -e
	return "${rc}"
}

# dry_run_note <text>: in dry-run mode print what would happen and return 0,
# otherwise return 1. Usage: dry_run_note "would delete X" && return 0
dry_run_note() {
	((DRY_RUN)) || return 1
	_log_to_file DRYRUN "$*"
	printf '    %s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(redact_string "$*")"
	return 0
}

# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

is_interactive() {
	[[ -t 0 && -t 1 ]]
}

# confirm <question>: yes/no question. --yes answers yes, non-interactive
# sessions answer no.
confirm() {
	((ASSUME_YES)) && return 0
	is_interactive || return 1
	local answer
	read -r -p "    $1 [y/N] " answer
	[[ ${answer} =~ ^[Yy]([Ee][Ss])?$ ]]
}

# confirm_typed <expected> <prompt>: require the user to type a value.
confirm_typed() {
	((ASSUME_YES)) && return 0
	is_interactive || return 1
	local answer
	read -r -p "    $2: " answer
	[[ ${answer} == "$1" ]]
}

# ---------------------------------------------------------------------------
# Traps
# ---------------------------------------------------------------------------

INTERRUPTED=0
_CLEANUP_FUNCS=()

# on_exit <function>: register a cleanup function (run in reverse order).
on_exit() {
	_CLEANUP_FUNCS+=("$1")
}

_run_cleanup() {
	local i
	for ((i = ${#_CLEANUP_FUNCS[@]} - 1; i >= 0; i--)); do
		"${_CLEANUP_FUNCS[i]}" || true
	done
	if [[ -n ${OKD_PVE_TMP} && -d ${OKD_PVE_TMP} && ${OKD_PVE_TMP} == */okd-pve.* ]]; then
		rm -rf "${OKD_PVE_TMP}"
	fi
}

_on_interrupt() {
	# Bash runs this only after the foreground child (e.g. tofu) has exited,
	# so tofu has already had the chance to finish and persist its state.
	INTERRUPTED=1
	trap - INT TERM
	printf '\n' >&2
	log_error "Interrupted."
	log_hint "State is saved in the cluster directory. Re-run the same command to continue where it stopped."
	exit "${EXIT_INTERRUPTED}"
}

setup_traps() {
	trap _run_cleanup EXIT
	trap _on_interrupt INT TERM
}

setup_tmp() {
	if [[ -z ${OKD_PVE_TMP} || ! -d ${OKD_PVE_TMP} ]]; then
		OKD_PVE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/okd-pve.XXXXXX")
		chmod 700 "${OKD_PVE_TMP}"
	fi
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# file_mode <path>: octal permission bits (Linux and macOS).
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# file_mtime <path>: modification time in epoch seconds (Linux and macOS).
file_mtime() {
	stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

# human_gib <bytes>
human_gib() {
	awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'
}

# free_bytes <dir>: available bytes on the filesystem holding dir.
free_bytes() {
	local d=$1
	while [[ ! -d $d ]]; do d=$(dirname "$d"); done
	df -Pk "$d" | awk 'NR == 2 { print $4 * 1024 }'
}

# version_ge <a> <b>: true if version a >= b (dotted numeric prefix only).
version_ge() {
	local a b i
	IFS=. read -r -a a <<<"${1%%-*}"
	IFS=. read -r -a b <<<"${2%%-*}"
	for ((i = 0; i < 3; i++)); do
		((${a[i]:-0} > ${b[i]:-0})) && return 0
		((${a[i]:-0} < ${b[i]:-0})) && return 1
	done
	return 0
}

# elapsed <start-epoch>: "1h02m03s" style duration.
elapsed() {
	local s=$((SECONDS - $1))
	if ((s >= 3600)); then
		printf '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
	elif ((s >= 60)); then
		printf '%dm%02ds' $((s / 60)) $((s % 60))
	else
		printf '%ds' "${s}"
	fi
}

# join_by <sep> <items...>
join_by() {
	local sep=$1 out='' item
	shift
	for item in "$@"; do
		out+=${out:+$sep}${item}
	done
	printf '%s' "${out}"
}

# wait_until <timeout-seconds> <interval> <description> <cmd...>
wait_until() {
	local timeout=$1 interval=$2 desc=$3 start=${SECONDS}
	shift 3
	until "$@"; do
		if ((SECONDS - start >= timeout)); then
			log_debug "Timed out after ${timeout}s waiting for: ${desc}"
			return 1
		fi
		sleep "${interval}"
	done
}
