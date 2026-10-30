# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Kubelet garbage collection, eviction thresholds and automatic
# system-reserved sizing for the {{POOL}} MachineConfigPool (Pre-Boot).
#
# Rendered separately for the master and the worker pool: a KubeletConfig
# that only selects the worker pool leaves the control plane on the defaults
# (image GC only starts at 85 % disk usage), and master disks then hover just
# below that threshold until an upgrade pushes them over.
#
# A dedicated infra pool inherits the worker MachineConfigs, including the
# one generated from this KubeletConfig.
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: okd-pve-{{POOL}}
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/{{POOL}}: ""
  autoSizingReserved: {{AUTO_SIZING}}
  kubeletConfig:
    imageGCHighThresholdPercent: {{GC_HIGH}}
    imageGCLowThresholdPercent: {{GC_LOW}}
    imageMinimumGCAge: {{GC_MIN_AGE}}
    evictionPressureTransitionPeriod: {{EVICTION_TRANSITION}}
    evictionHard:
      {{EVICTION_HARD}}
    evictionSoft:
      {{EVICTION_SOFT}}
    evictionSoftGracePeriod:
      {{EVICTION_SOFT_GRACE}}
