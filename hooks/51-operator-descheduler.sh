#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Kube Descheduler operator and its KubeDescheduler resource.
#
#   DESCHEDULER_INTERVAL      seconds between runs, default: 3600
#   DESCHEDULER_PROFILES      space separated, default: "AffinityAndTaints LifecycleAndUtilization"
#   DESCHEDULER_POD_LIFETIME  for LifecycleAndUtilization, default: 24h
#   DESCHEDULER_MODE          Automatic or Predictive (dry run), default: Automatic
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

install_operator_by_key descheduler
ns=$(operator_coordinates descheduler | awk '{ print $3 }')
profiles=${DESCHEDULER_PROFILES:-AffinityAndTaints LifecycleAndUtilization}

jq -n --arg ns "${ns}" --argjson interval "${DESCHEDULER_INTERVAL:-3600}" --arg profiles "${profiles}" \
	--arg lifetime "${DESCHEDULER_POD_LIFETIME:-24h}" --arg mode "${DESCHEDULER_MODE:-Automatic}" '{
	apiVersion: "operator.openshift.io/v1",
	kind: "KubeDescheduler",
	metadata: {name: "cluster", namespace: $ns},
	spec: ({
		managementState: "Managed",
		mode: $mode,
		deschedulingIntervalSeconds: $interval,
		profiles: ($profiles | split(" ") | map(select(. != "")))
	} + (if ($profiles | test("LifecycleAndUtilization")) then {profileCustomizations: {podLifetime: $lifetime}} else {} end))
}' | apply_idempotent -
