# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Standard OKD install-config.yaml for cluster "{{NAME}}". okd-pve only
# validates it and fills in controlPlane/compute replicas (from cluster.yaml),
# pullSecret and sshKey (if missing) in a generated copy. This file is never
# modified or consumed.
apiVersion: v1
baseDomain: example.com
metadata:
  name: {{NAME}}
networking:
  networkType: OVNKubernetes
  machineNetwork:
    - cidr: 192.0.2.0/24
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
# The cluster brings its own API and ingress VIPs (keepalived); no external
# load balancer needed. DNS: api.{{NAME}}.example.com -> apiVIPs,
# *.apps.{{NAME}}.example.com -> ingressVIPs.
# Single-node clusters use "platform: {none: {}}" instead (DNS -> node IP).
platform:
  baremetal:
    apiVIPs:
      - 192.0.2.5
    ingressVIPs:
      - 192.0.2.6
# Optional: CA bundle for proxies/registries, cluster-wide.
# additionalTrustBundle: |
#   -----BEGIN CERTIFICATE-----
#   ...
