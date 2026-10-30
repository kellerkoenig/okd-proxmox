# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Additional SSH keys for the core user of the {{ROLE}} pool (Pre-Boot).
#
# install-config.yaml sshKey carries only the first key: on baremetal the
# cluster-baremetal-operator copies sshKey verbatim into the Ironic kernel
# parameters, and a second key (a newline) breaks Ironic and with it the
# machine-api operator. The Machine Config Operator merges the keys of all
# MachineConfigs for the core user, so the other keys go here.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: {{NAME}}
  labels:
    machineconfiguration.openshift.io/role: {{ROLE}}
spec:
  config:
    ignition:
      version: 3.2.0
    passwd:
      users:
        - name: core
          sshAuthorizedKeys:
            {{KEYS}}
