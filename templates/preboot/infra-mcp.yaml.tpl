# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Dedicated infra MachineConfigPool (Pre-Boot). Only rendered when every node
# group with the infra role is a dedicated infra group: a node that matches
# two custom pools goes Degraded and accepts no MachineConfig at all, so
# combined worker/infra nodes stay in the worker pool.
#
# The pool inherits all worker MachineConfigs (role in [worker, infra]).
# Nodes are installed as workers and move into this pool once okd-pve labels
# them; with identical rendered content that move does not reboot them.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: infra
  labels:
    pools.operator.machineconfiguration.openshift.io/infra: ""
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: [worker, infra]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/infra: ""
