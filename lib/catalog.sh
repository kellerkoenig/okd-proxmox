# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Operator catalog profiles. Hooks and storage backends ask this file for
# package, channel, namespace and catalog source of an operator instead of
# hard-coding them.
#
#   OKD_PVE_CATALOG_PROFILE=okderators   OKD community catalog (default,
#                                        quay.io/okderators/catalog-index)
#   OKD_PVE_CATALOG_PROFILE=redhat       redhat-operators (needs a Red Hat
#                                        pull secret for registry.redhat.io)
#
# Every value can be overridden per operator, e.g. for key "logging":
#   OKD_PVE_OP_LOGGING_PACKAGE / _CHANNEL / _NAMESPACE / _SOURCE

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_CATALOG_LOADED:-} ]] && return 0
_OKD_PVE_CATALOG_LOADED=1

# key -> "package channel namespace" per profile. "-" = not available.
# key -> "package channel namespace" per profile. "-" = not available.
# "@default" = the package's default channel in the catalog; pin a channel
# with OKD_PVE_OP_<KEY>_CHANNEL when you need reproducible operator versions.
declare -gA _CATALOG_REDHAT=(
	["logging"]="cluster-logging @default openshift-logging"
	["descheduler"]="cluster-kube-descheduler-operator @default openshift-kube-descheduler-operator"
	["cluster-resource-override"]="clusterresourceoverride @default clusterresourceoverride-operator"
	["cert-manager"]="openshift-cert-manager-operator @default cert-manager-operator"
	["web-terminal"]="web-terminal @default openshift-operators"
	["local-storage"]="local-storage-operator @default openshift-local-storage"
	["odf"]="odf-operator @default openshift-storage"
	["gitops"]="openshift-gitops-operator @default openshift-gitops-operator"
)
declare -gA _CATALOG_OKDERATORS=(
	["logging"]="cluster-logging @default openshift-logging"
	["descheduler"]="cluster-kube-descheduler-operator @default openshift-kube-descheduler-operator"
	["cluster-resource-override"]="-"
	["cert-manager"]="cert-manager-operator @default cert-manager-operator"
	["web-terminal"]="web-terminal @default openshift-operators"
	["local-storage"]="local-storage-operator @default openshift-local-storage"
	["odf"]="odf-operator @default openshift-storage"
	["gitops"]="gitops-operator @default openshift-gitops-operator"
)

catalog_profile() {
	printf '%s' "${OKD_PVE_CATALOG_PROFILE:-okderators}"
}

catalog_default_source() {
	case $(catalog_profile) in
	redhat) echo redhat-operators ;;
	okderators) echo okderators ;;
	*) echo "${OKD_PVE_CATALOG_PROFILE}" ;;
	esac
}

# operator_coordinates <key>: prints "package channel namespace source".
# Returns 1 when the operator is not available in the profile and no
# override is set.
operator_coordinates() {
	local key=$1 env_key entry pkg channel ns source
	env_key=OKD_PVE_OP_$(tr '[:lower:]-' '[:upper:]_' <<<"${key}")
	case $(catalog_profile) in
	redhat) entry=${_CATALOG_REDHAT[${key}]:-} ;;
	*) entry=${_CATALOG_OKDERATORS[${key}]:-} ;;
	esac
	read -r pkg channel ns <<<"${entry}"
	local v
	v=${env_key}_PACKAGE && pkg=${!v:-${pkg}}
	v=${env_key}_CHANNEL && channel=${!v:-${channel}}
	v=${env_key}_NAMESPACE && ns=${!v:-${ns}}
	v=${env_key}_SOURCE && source=${!v:-$(catalog_default_source)}
	[[ -n ${pkg} && ${pkg} != - && -n ${channel} && -n ${ns} ]] || return 1
	printf '%s %s %s %s\n' "${pkg}" "${channel}" "${ns}" "${source}"
}

# install_operator_by_key <key>: install_operator with catalog coordinates.
install_operator_by_key() {
	local coords
	if ! coords=$(operator_coordinates "$1"); then
		_oclib_log error "Operator '$1' is not available in catalog profile $(catalog_profile). Set OKD_PVE_OP_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_PACKAGE/_CHANNEL/_NAMESPACE/_SOURCE."
		return 1
	fi
	# shellcheck disable=SC2086
	install_operator ${coords}
}
