# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Pinned tool versions and their download locations. Override a version with
# the matching environment variable, e.g. OKD_PVE_TOFU_VERSION=1.13.3.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_VERSIONS_LOADED:-} ]] && return 0
_OKD_PVE_VERSIONS_LOADED=1

OKD_PVE_VERSION=0.1.1

OKD_MIN_VERSION=4.17

# "# renovate:" comments let Renovate propose updates (.github/renovate.json5).
# renovate: datasource=github-releases depName=opentofu/opentofu
TOFU_VERSION=${OKD_PVE_TOFU_VERSION:-1.13.2}
TOFU_MIN_VERSION=1.8.0
TOFU_URL_BASE=https://github.com/opentofu/opentofu/releases/download

# Updating Butane needs new checksums below; Renovate only opens that pull
# request after approval in its dependency dashboard.
# renovate: datasource=github-releases depName=coreos/butane
BUTANE_VERSION=${OKD_PVE_BUTANE_VERSION:-0.29.0}
BUTANE_URL_BASE=https://github.com/coreos/butane/releases/download
# Butane publishes GPG signatures only; these checksums were taken from
# release binaries whose Fedora signatures were verified.
declare -gA BUTANE_SHA256=(
	["0.29.0/x86_64-unknown-linux-gnu"]=53a20d820fbaa7fda4f1afd1814974badc8e448db4c151d3f1ba005dc29bc4c9
	["0.29.0/aarch64-unknown-linux-gnu"]=12c1d78eeffc72dab9c8383d9b79d7d6e6e0d6ec6fe8f19eaf93d9e13eef286f
	["0.29.0/x86_64-apple-darwin"]=89a66e40058cdaa9ba5f2fbbdc1af91812ba0f321f29f99e589fa445bd51226c
	["0.29.0/aarch64-apple-darwin"]=9d27a4093e4908d6a66b3996ccf4aaf2ea6123972809c4d47dc1b14ac05d8417
)

OKD_URL_BASE=https://github.com/okd-project/okd/releases/download
OKD_RELEASE_IMAGE_REPO=quay.io/okd/scos-release

# OpenTofu provider for Proxmox VE.
PROXMOX_PROVIDER_SOURCE=bpg/proxmox
# renovate: datasource=terraform-provider depName=bpg/proxmox
PROXMOX_PROVIDER_VERSION=${OKD_PVE_PROXMOX_PROVIDER_VERSION:-0.117.0}

# Image used to extract nmstatectl where no nmstate package exists.
NMSTATE_SOURCE_IMAGE=${OKD_PVE_NMSTATE_IMAGE:-quay.io/centos/centos:stream9}

# Butane spec version for rendered MachineConfigs (oldest supported OKD).
BUTANE_OPENSHIFT_SPEC=4.17.0

# Proxmox VE major versions we support (8.x and 9.x are maintained upstream).
PVE_MIN_VERSION=8.0
