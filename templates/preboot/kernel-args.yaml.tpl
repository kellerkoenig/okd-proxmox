# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Additional kernel arguments for the {{ROLE}} pool (Pre-Boot). Applied at
# install time this costs nothing; applied later it reboots every node of
# the pool. For a dedicated infra pool these arguments are added on top of
# the inherited worker arguments.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: {{NAME}}
  labels:
    machineconfiguration.openshift.io/role: {{ROLE}}
spec:
  kernelArguments:
    {{KARGS}}
