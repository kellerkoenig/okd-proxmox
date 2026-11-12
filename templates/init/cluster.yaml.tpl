# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# cluster.yaml for cluster "{{NAME}}": everything Proxmox-specific and the
# node topology. Cluster name and base domain come from install-config.yaml.
# Unset keys fall back to templates/cluster-defaults.yaml in the okd-pve
# repository. Credentials never go here (see proxmox.conf).

okd:
  # OKD release tag from https://github.com/okd-project/okd/releases (>= 4.17).
  # The SCOS version is part of the release and cannot be chosen separately.
  version: "4.21.0-okd-scos.11"

install:
  # Used when install-config.yaml has no pullSecret/sshKey. Without a pull
  # secret the OKD placeholder is used (fine unless you need registry.redhat.io).
  pull_secret_file: ""            # e.g. pull-secret.json (relative to this directory)
  ssh_public_key_file: ""         # default: ~/.ssh/id_ed25519.pub, id_ecdsa.pub, id_rsa.pub
  debug_shell: false              # debugging: root shell on tty9 of the live ISO (Proxmox console)

proxmox:
  # Target node(s). Control-plane VMs are spread round-robin across them.
  nodes: [pve1, pve2, pve3]
  spread: true                    # balanced: shift each group by one node; false: all on the first
  vm_storage: local-lvm           # boot disks (content type: images)
  iso_storage: local              # agent ISO (content type: iso)
  efi_storage: ""                 # EFI vars disks, default: vm_storage
  bridge: vmbr0
  vlan_tag: 0                     # 0 = untagged
  pool: okd-{{NAME}}              # must exist (docs/proxmox-permissions.md)
  # VMIDs are assigned deterministically: vmid_start + group offset + index.
  # Group offset = position of the group in node_groups * vmid_block.
  vmid_start: 4100
  vmid_end: 4199
  vmid_block: 20
  # MACs = prefix + VMID; stable across rebuilds. Use a locally administered
  # prefix (second hex digit 2, 6, A or E).
  mac_prefix: "02:00:00"
  cpu_type: host                  # SCOS 10 needs x86-64-v3 or host
  bios: ovmf                      # ovmf (UEFI) or seabios
  # Local work directories, each needs ~2 GiB. Relative to the cluster
  # directory, e.g. .tmp and .cache when /tmp or the home directory is small.
  tmp_dir: ""                     # TMPDIR: ISO upload buffer, downloads; default $TMPDIR or /tmp
  cache_dir: ""                   # XDG_CACHE_HOME: base ISO, OpenTofu providers; default ~/.cache
  host_memory_reserve_gib: 8      # RAM kept free per host in the capacity check

network:
  interface: ens18                # NIC name inside SCOS (ens18 for net0 on Proxmox)
  prefix_length: 24
  gateway: 192.0.2.1
  dns_servers: [192.0.2.53]
  # At least three sources: with two, chrony cannot tell which one is wrong.
  ntp_servers: [192.0.2.123, 192.0.2.124, 192.0.2.125]
  rendezvous_ip: 192.0.2.11       # IP of one control-plane node

# Hostname = Kubernetes node name = Proxmox VM name. Placeholders: {cluster},
# {group}, {index}, {domain}. Keep {cluster} in it (VM names must be unique
# on the Proxmox cluster). FQDN example: "{group}-{index}.{cluster}.{domain}"
hostname_format: "{cluster}-{group}-{index}"

# Node groups. roles is a list: master | worker | infra.
#   - taint_infra decides everything for infra: tainted nodes only run
#     workloads that tolerate the taint, the worker label does not change that.
#   - combined worker+infra nodes stay in the worker MachineConfigPool.
#   - ips: one address per node, ranges allowed ("192.0.2.21-192.0.2.29");
#     list spare addresses for later "okd-pve node add".
#   - data_disks: extra raw disks in GiB (LSO/ODF/Ceph), stable serials.
#   - Add new groups at the end: the position determines the VMID offset.
node_groups:
  - name: master
    roles: [master]
    count: 3
    cpu: 8
    memory_gib: 32
    disk_gib: 120
    ips: [192.0.2.11, 192.0.2.12, 192.0.2.13]

  - name: worker
    roles: [worker, infra]
    taint_infra: false
    count: 3
    cpu: 8
    memory_gib: 64
    disk_gib: 256
    data_disks: []
    ips: ["192.0.2.21-192.0.2.29"]

  # Dedicated infra nodes instead of combined ones:
  # - name: infra
  #   roles: [infra]
  #   taint_infra: true
  #   count: 3
  #   cpu: 8
  #   memory_gib: 64
  #   disk_gib: 256
  #   ips: ["192.0.2.31-192.0.2.39"]

infra:
  # Key and value used in every taint, toleration and manifest.
  taint_key: node-role.kubernetes.io/infra
  taint_value: reserved
  taint_effects: [NoSchedule]
  combined_min_memory_gib: 48     # warn below this RAM for worker+infra nodes

# Pre-Boot: rendered into the ISO, effective at first boot, no reboots.
preboot:
  chrony: true
  kubelet: true                   # GC/eviction/autoSizingReserved for master AND worker
  kernel_args:
    master: ["console=tty0", "console=ttyS0,115200n8"]
    worker: ["console=tty0", "console=ttyS0,115200n8"]
  ca_bundle_file: ""              # PEM file with extra CAs for the node trust store

kubelet:
  image_gc_high_threshold_percent: 80
  image_gc_low_threshold_percent: 70
  image_minimum_gc_age: 5m

storage:
  backend: none                   # none | proxmox-csi | ceph-external | lso | nfs
  storage_class: okd-pve
  retain_class: true              # also create okd-pve-retain (reclaimPolicy Retain)
  default: false                  # mark as default StorageClass (see docs/storage.md)
  # proxmox_csi: {storage: local-lvm, region: ""}   # token: proxmox-csi.conf
  # ceph: {cluster_id: "", monitors: [], pool: "", user: ""}   # key: ceph-csi.conf
  # lso: {node_groups: [worker], odf: false}
  # nfs: {server: 192.0.2.200, path: /export/okd}

# Registry mirrors (pull-through caches), optional; see docs/registry-mirrors.md.
# registry_mirrors:
#   fallback: false                 # true: pull from the source if the mirror fails
#   username: svc-okd               # one login for all mirrors (an entry can set its own)
#   password: ""                    # or export OKD_PVE_MIRROR_PASSWORD (keeps it out of this file)
#   # auth_file: mirror-auth.json   # alternative: podman login --authfile mirror-auth.json <host>
#   registries:
#     - {source: quay.io, mirror: quay-cache.example.com}
#     - {source: registry.redhat.io, mirror: redhat-cache.example.com}

monitoring:
  storage_class: ""               # StorageClass for Prometheus/Alertmanager PVCs

hooks:
  dir: ""                         # external (private) hooks directory
  # Built-in example hooks to run ("all" or a list); see 'okd-pve hooks list'.
  builtin:
    - 10-infra-nodes
    - 30-ingress-controller
    - 40-monitoring
  skip: []
  env:
    OKD_PVE_CATALOG_PROFILE: okderators   # or: redhat (needs a Red Hat pull secret)
    INGRESS_REPLICAS: "2"
