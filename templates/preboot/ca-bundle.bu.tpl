# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Additional CA certificates in the node trust store of the {{ROLE}} pool
# (Pre-Boot). coreos-update-ca-trust.service picks up the anchor at boot.
#
# This covers the host (CRI-O pulling from an internal registry, chrony
# with NTS, ...). For the cluster-wide proxy trust bundle use
# additionalTrustBundle in install-config.yaml.
variant: openshift
version: {{BUTANE_SPEC}}
metadata:
  name: {{NAME}}
  labels:
    machineconfiguration.openshift.io/role: {{ROLE}}
storage:
  files:
    - path: /etc/pki/ca-trust/source/anchors/okd-pve-extra-ca.crt
      mode: 0644
      overwrite: true
      contents:
        local: {{CA_FILE}}
