#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Web Terminal operator (pulls in the DevWorkspace operator) and the idle
# timeout of terminals.
#
#   WEB_TERMINAL_IDLE_TIMEOUT  default: 15m
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

install_operator_by_key web-terminal
wait_for_crd devworkspaceoperatorconfigs.controller.devfile.io

apply_idempotent - <<YAML
apiVersion: controller.devfile.io/v1alpha1
kind: DevWorkspaceOperatorConfig
metadata:
  name: devworkspace-operator-config
  namespace: openshift-operators
config:
  workspace:
    idleTimeout: ${WEB_TERMINAL_IDLE_TIMEOUT:-15m}
YAML
