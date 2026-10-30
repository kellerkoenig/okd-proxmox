# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Provides openshift-install, oc, tofu, butane and nmstatectl in a matching
# version. Binaries from $PATH are preferred; otherwise they are downloaded
# (after confirmation) into <cluster>/bin with checksum verification.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_TOOLS_LOADED:-} ]] && return 0
_OKD_PVE_TOOLS_LOADED=1

OPENSHIFT_INSTALL=''
OC=''
TOFU=''
BUTANE=''

host_os() {
	case $(uname -s) in
	Linux) echo linux ;;
	Darwin) echo darwin ;;
	*) uname -s | tr '[:upper:]' '[:lower:]' ;;
	esac
}

host_arch() {
	case $(uname -m) in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) uname -m ;;
	esac
}

# _candidates <name>: PATH entry first, then the cluster bin directory.
_candidates() {
	local p
	p=$(command -v "$1" 2>/dev/null) && printf '%s\n' "${p}"
	[[ -n ${BIN_DIR:-} && -x ${BIN_DIR}/$1 ]] && printf '%s\n' "${BIN_DIR}/$1"
	return 0
}

openshift_install_version() {
	"$1" version 2>/dev/null | awk 'NR == 1 { print $2 }'
}

oc_client_version() {
	"$1" version --client -o json 2>/dev/null | jq -r '.releaseClientVersion // .clientVersion.gitVersion // empty' |
		sed 's/^v//'
}

tofu_version() {
	"$1" version -json 2>/dev/null | jq -r '.terraform_version // empty'
}

butane_version() {
	"$1" --version 2>/dev/null | awk '{ print $2 }'
}

# minor_distance <a> <b>: absolute difference of the minor versions when the
# major versions match, 99 otherwise.
minor_distance() {
	local a b
	IFS=. read -r -a a <<<"$1"
	IFS=. read -r -a b <<<"$2"
	if [[ ${a[0]:-x} != "${b[0]:-y}" ]]; then
		echo 99
		return
	fi
	local d=$((${a[1]:-0} - ${b[1]:-0}))
	echo "${d#-}"
}

# tool_check <name>: print "<path>\t<version>" of the first suitable binary.
tool_check() {
	local name=$1 c v want
	while IFS= read -r c; do
		case ${name} in
		openshift-install)
			want=$(cfg '.okd.version')
			v=$(openshift_install_version "${c}")
			[[ ${v} == "${want}" ]] || {
				log_debug "${c}: version ${v:-unknown}, need ${want}"
				continue
			}
			;;
		oc)
			v=$(oc_client_version "${c}")
			(($(minor_distance "${v}" "$(okd_minor)") <= 1)) ||
				{
					log_debug "${c}: version ${v:-unknown} too far from $(okd_minor)"
					continue
				}
			;;
		tofu)
			v=$(tofu_version "${c}")
			version_ge "${v:-0}" "${TOFU_MIN_VERSION}" || {
				log_debug "${c}: version ${v:-unknown} < ${TOFU_MIN_VERSION}"
				continue
			}
			;;
		butane)
			v=$(butane_version "${c}")
			version_ge "${v:-0}" 0.22.0 || {
				log_debug "${c}: version ${v:-unknown} < 0.22.0"
				continue
			}
			;;
		nmstatectl)
			v=$("${c}" --version 2>/dev/null | awk '{ print $2 }')
			[[ -n ${v} ]] || continue
			;;
		esac
		printf '%s\t%s\n' "${c}" "${v}"
		return 0
	done < <(_candidates "${name}")
	return 1
}

# tools_ensure [names...]: resolve (and if needed download) the tools.
tools_ensure() {
	local names=("$@") name found missing=()
	((${#names[@]})) || names=(openshift-install oc tofu butane nmstatectl)
	for name in "${names[@]}"; do
		if found=$(tool_check "${name}"); then
			_tool_set "${name}" "${found%%$'\t'*}"
			log_debug "Using ${name} ${found#*$'\t'} from ${found%%$'\t'*}"
		else
			missing+=("${name}")
		fi
	done
	((${#missing[@]})) || return 0

	log_info "Missing or unsuitable tools: ${missing[*]}"
	if dry_run_note "would download ${missing[*]} into ${BIN_DIR}"; then
		return 0
	fi
	confirm "Download ${missing[*]} into ${BIN_DIR}?" ||
		die "${EXIT_ERROR}" "Required tools are missing: ${missing[*]}" \
			"Install them into PATH, or re-run with --yes to download them into ${BIN_DIR}."
	mkdir -p "${BIN_DIR}"
	for name in "${missing[@]}"; do
		"_download_${name//-/_}"
		found=$(tool_check "${name}") ||
			die "${EXIT_ERROR}" "Downloaded ${name} is not usable." "Check ${LOG_FILE} for details."
		_tool_set "${name}" "${found%%$'\t'*}"
		log_ok "${name} ${found#*$'\t'} installed into ${BIN_DIR}"
	done
}

_tool_set() {
	case $1 in
	openshift-install) OPENSHIFT_INSTALL=$2 ;;
	oc) OC=$2 ;;
	tofu) TOFU=$2 ;;
	butane) BUTANE=$2 ;;
	esac
}

# tools_path: put <cluster>/bin first in PATH so that programs started by
# okd-pve (openshift-install calls nmstatectl) find the provided tools.
tools_path() {
	[[ -n ${BIN_DIR:-} && :${PATH}: != *":${BIN_DIR}:"* ]] || return 0
	PATH=${BIN_DIR}:${PATH}
	export PATH
}

# fetch <url> <dest>
fetch() {
	log_debug "Downloading $1"
	curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" ||
		die "${EXIT_ERROR}" "Download failed: $1" "Check network/proxy access to github.com."
}

# verify_sha256 <file> <expected>
verify_sha256() {
	local got
	got=$(sha256_file "$1")
	[[ ${got} == "$2" ]] ||
		die "${EXIT_ERROR}" "Checksum mismatch for ${1##*/} (expected $2, got ${got})." \
			"Delete the file and retry; if it persists, the download may be tampered with."
	log_debug "Checksum OK: ${1##*/}"
}

# checksum_from_list <list-file> <filename>
checksum_from_list() {
	awk -v f="$2" '$2 == f || $2 == "*" f { print $1; exit }' "$1"
}

_okd_asset_suffix() {
	local os arch
	os=$(host_os) arch=$(host_arch)
	case ${os}/${arch} in
	linux/amd64) echo linux ;;
	linux/arm64) echo linux-arm64 ;;
	darwin/amd64) echo mac ;;
	darwin/arm64) echo mac-arm64 ;;
	*) die "${EXIT_ERROR}" "No OKD client binaries for ${os}/${arch}." ;;
	esac
}

_download_okd_tarball() {
	local kind=$1 ver dl file sums
	ver=$(cfg '.okd.version')
	dl=$(mktemp -d "${OKD_PVE_TMP}/dl.XXXXXX")
	file="${kind}-$(_okd_asset_suffix)-${ver}.tar.gz"
	fetch "${OKD_URL_BASE}/${ver}/sha256sum.txt" "${dl}/sha256sum.txt"
	fetch "${OKD_URL_BASE}/${ver}/${file}" "${dl}/${file}"
	sums=$(checksum_from_list "${dl}/sha256sum.txt" "${file}")
	[[ -n ${sums} ]] || die "${EXIT_ERROR}" "${file} is not listed in the release checksums." \
		"Check okd.version (${ver}) against https://github.com/okd-project/okd/releases"
	verify_sha256 "${dl}/${file}" "${sums}"
	tar -xzf "${dl}/${file}" -C "${dl}"
	printf '%s' "${dl}"
}

_download_openshift_install() {
	local dl
	log_info "Downloading openshift-install $(cfg '.okd.version')"
	dl=$(_download_okd_tarball openshift-install)
	install -m 0755 "${dl}/openshift-install" "${BIN_DIR}/openshift-install"
}

_download_oc() {
	local dl
	log_info "Downloading oc $(cfg '.okd.version')"
	dl=$(_download_okd_tarball openshift-client)
	install -m 0755 "${dl}/oc" "${BIN_DIR}/oc"
}

_download_tofu() {
	local dl file sums
	have_cmd unzip || die "${EXIT_ERROR}" "unzip is required to install OpenTofu." "Install unzip or install tofu yourself."
	log_info "Downloading OpenTofu ${TOFU_VERSION}"
	dl=$(mktemp -d "${OKD_PVE_TMP}/dl.XXXXXX")
	file="tofu_${TOFU_VERSION}_$(host_os)_$(host_arch).zip"
	fetch "${TOFU_URL_BASE}/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS" "${dl}/SHA256SUMS"
	fetch "${TOFU_URL_BASE}/v${TOFU_VERSION}/${file}" "${dl}/${file}"
	sums=$(checksum_from_list "${dl}/SHA256SUMS" "${file}")
	[[ -n ${sums} ]] || die "${EXIT_ERROR}" "${file} is not listed in the OpenTofu checksums."
	verify_sha256 "${dl}/${file}" "${sums}"
	unzip -qo "${dl}/${file}" tofu -d "${dl}"
	install -m 0755 "${dl}/tofu" "${BIN_DIR}/tofu"
}

_download_butane() {
	local dl triple want arch key
	arch=$(host_arch)
	[[ ${arch} == amd64 ]] && arch=x86_64
	[[ ${arch} == arm64 ]] && arch=aarch64
	case $(host_os) in
	linux) triple=${arch}-unknown-linux-gnu ;;
	darwin) triple=${arch}-apple-darwin ;;
	esac
	# A separate key variable: shfmt would turn "a/b" inside [] into arithmetic.
	key="${BUTANE_VERSION}/${triple}"
	want=${BUTANE_SHA256[${key}]:-}
	[[ -n ${want} ]] || die "${EXIT_ERROR}" "No pinned checksum for butane ${BUTANE_VERSION} (${triple})." \
		"Install butane yourself (https://coreos.github.io/butane/getting-started/) or use the default version."
	log_info "Downloading butane ${BUTANE_VERSION}"
	dl=$(mktemp -d "${OKD_PVE_TMP}/dl.XXXXXX")
	fetch "${BUTANE_URL_BASE}/v${BUTANE_VERSION}/butane-${triple}" "${dl}/butane"
	verify_sha256 "${dl}/butane" "${want}"
	install -m 0755 "${dl}/butane" "${BIN_DIR}/butane"
}

# container_engine: podman or docker, whichever is installed.
container_engine() {
	if have_cmd podman; then
		echo podman
	elif have_cmd docker; then
		echo docker
	else
		return 1
	fi
}

# _download_nmstatectl: nmstate publishes no binaries and several
# distributions (e.g. Ubuntu) do not package it. openshift-install only needs
# "nmstatectl gc", which works offline, so the binary of the signed CentOS
# Stream 9 package is extracted with podman/docker (dnf verifies the
# package signature).
_download_nmstatectl() {
	local engine dl
	[[ $(host_os) == linux ]] || die "${EXIT_ERROR}" "nmstatectl is missing." \
		"There is no nmstate build for macOS; run okd-pve create on Linux."
	engine=$(container_engine) || die "${EXIT_ERROR}" "nmstatectl is missing and neither podman nor docker is installed." \
		"Install nmstate (dnf install nmstate), or install podman/docker so okd-pve can extract it."
	log_info "Extracting nmstatectl from the CentOS Stream 9 nmstate package (${engine})"
	dl=$(mktemp -d "${OKD_PVE_TMP}/dl.XXXXXX")
	chmod 777 "${dl}"
	run_logged "${engine}" run --rm -v "${dl}:/out:Z" "${NMSTATE_SOURCE_IMAGE}" \
		bash -c 'dnf -y -q install nmstate && cp /usr/bin/nmstatectl /out/ && rpm -q nmstate' ||
		die "${EXIT_ERROR}" "Extracting nmstatectl failed." "See ${LOG_FILE}; or install nmstate yourself."
	install -m 0755 "${dl}/nmstatectl" "${BIN_DIR}/nmstatectl"
}

# oc_cmd <args...>: oc against this cluster.
oc_cmd() {
	KUBECONFIG=${KUBECONFIG_FILE} "${OC:-oc}" "$@"
}
