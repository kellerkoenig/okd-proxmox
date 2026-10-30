#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Infra labels and taints as configured in cluster.yaml. create already does
# this; the hook keeps it in the hook set so a "hooks run" after manual
# changes restores the configured state.
set -euo pipefail

if [[ ${OKD_PVE_INFRA_NODE_COUNT:-0} == 0 ]]; then
	echo "No infra nodes configured; nothing to do."
	exit 0
fi
exec "${OKD_PVE_BIN:?run via okd-pve hooks run}" --no-color --dir "${OKD_PVE_CLUSTER_DIR}" node reconcile
