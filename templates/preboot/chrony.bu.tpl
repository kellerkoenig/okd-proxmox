# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# chrony configuration for the {{ROLE}} MachineConfigPool (Pre-Boot).
#
# Shipped as a Pre-Boot manifest, nodes never start with the OKD default NTP
# servers, which are unreachable in isolated networks and cause
# "Can't synchronise: no majority" errors on first boot. Applied after
# installation, the same MachineConfig would reboot every node of the pool.
#
# Number of sources: with exactly two servers chrony cannot decide which one
# is wrong when they disagree, there is no majority. Configure three or more.
variant: openshift
version: {{BUTANE_SPEC}}
metadata:
  name: {{NAME}}
  labels:
    machineconfiguration.openshift.io/role: {{ROLE}}
storage:
  files:
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          # Managed by okd-pve (Pre-Boot manifest {{NAME}}).
          {{SERVER_LINES}}
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          keyfile /etc/chrony.keys
          leapsectz right/UTC
          logdir /var/log/chrony
