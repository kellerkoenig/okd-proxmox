#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Logging operator plus the collector service account with the permissions
# to read application, infrastructure and audit logs.
#
# Where logs go (ClusterLogForwarder outputs) is application-level
# configuration and belongs to the deployment automation. To apply one here
# anyway, point LOGGING_FORWARDER_MANIFEST at a ClusterLogForwarder YAML.
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

install_operator_by_key logging
ns=$(operator_coordinates logging | awk '{ print $3 }')

oc get serviceaccount logcollector -n "${ns}" >/dev/null 2>&1 || oc create serviceaccount logcollector -n "${ns}" >/dev/null
for role in collect-application-logs collect-infrastructure-logs collect-audit-logs logging-collector-logs-writer; do
	if oc get clusterrole "${role}" >/dev/null 2>&1; then
		oc adm policy add-cluster-role-to-user "${role}" -z logcollector -n "${ns}" >/dev/null
	fi
done
echo "Service account ${ns}/logcollector can collect application, infrastructure and audit logs."

if [[ -n ${LOGGING_FORWARDER_MANIFEST:-} ]]; then
	wait_for_crd clusterlogforwarders.observability.openshift.io
	apply_idempotent "${LOGGING_FORWARDER_MANIFEST}"
else
	echo "No ClusterLogForwarder applied (set LOGGING_FORWARDER_MANIFEST, or leave it to your deployment automation)."
fi
