#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# cert-manager operator and its CertManager resource. Issuers (ACME, internal
# CA) are application-level configuration and belong to the deployment
# automation.
#
#   CERT_MANAGER_LOG_LEVEL  Normal, Debug, Trace, TraceAll; default: Normal
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

install_operator_by_key cert-manager
wait_for_crd certmanagers.operator.openshift.io

apply_idempotent - <<YAML
apiVersion: operator.openshift.io/v1alpha1
kind: CertManager
metadata:
  name: cluster
spec:
  managementState: Managed
  logLevel: ${CERT_MANAGER_LOG_LEVEL:-Normal}
  operatorLogLevel: Normal
YAML
oc_wait 600 "cert-manager deployments in namespace cert-manager" \
	oc -n cert-manager rollout status deployment/cert-manager --timeout=10s
