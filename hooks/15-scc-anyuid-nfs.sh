#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Allow nfs volumes in the anyuid SCC, for workloads that mount NFS exports
# directly in the pod spec. Idempotent: only adds "nfs" when it is missing.
#
# Note: changing a default SCC is a deliberate deviation from the defaults;
# consider a custom SCC (copy of anyuid plus nfs) for new setups.
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"

volumes=$(oc get scc anyuid -o json | jq -c '.volumes')
if jq -e 'index("nfs") or index("*")' <<<"${volumes}" >/dev/null; then
	echo "SCC anyuid already allows nfs volumes."
	exit 0
fi
oc patch scc anyuid --type json -p '[{"op": "add", "path": "/volumes/-", "value": "nfs"}]'
echo "Added nfs to the volumes of SCC anyuid."
