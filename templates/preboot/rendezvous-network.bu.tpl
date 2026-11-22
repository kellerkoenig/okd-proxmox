# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Static network of the rendezvous host (Pre-Boot, master pool).
#
# The agent-based installer copies each host's static network configuration
# (NetworkManager keyfiles generated from agent-config.yaml) onto the
# installed disk. With OKD 5.0 it skipped that for the rendezvous host, which
# is installed last: on first boot coreos-copy-firstboot-network found "no
# files to copy", the node took a DHCP address, and etcd never got its third
# member (the etcd operator only scales up nodes whose IP a Machine
# references, and it issued the node's etcd certificates for the DHCP
# address).
#
# This MachineConfig carries the keyfiles of the rendezvous host. On first
# boot, before NetworkManager starts, the unit installs them only if
# /etc/NetworkManager/system-connections is empty and one of the host's MAC
# addresses is present, i.e. only where the installer did not copy them.
# Everywhere else it does nothing.
variant: openshift
version: {{BUTANE_SPEC}}
metadata:
  name: {{NAME}}
  labels:
    machineconfiguration.openshift.io/role: master
storage:
  files:
    - path: /etc/okd-pve/rendezvous-network/macs
      mode: 0644
      contents:
        inline: |
          {{MACS}}
    {{KEYFILES}}
    - path: /usr/local/bin/okd-pve-rendezvous-network.sh
      mode: 0755
      contents:
        inline: |
          #!/bin/bash
          # Managed by okd-pve (Pre-Boot manifest {{NAME}}).
          set -euo pipefail
          shopt -s nullglob
          src=/etc/okd-pve/rendezvous-network
          dst=/etc/NetworkManager/system-connections
          done=/var/lib/okd-pve/rendezvous-network.checked
          mkdir -p "${done%/*}"
          existing=("${dst}"/*.nmconnection)
          match=0
          while read -r mac; do
            [[ -n ${mac} ]] || continue
            for a in /sys/class/net/*/address; do
              [[ $(<"${a}") == "${mac,,}" ]] && match=1
            done
          done <"${src}/macs"
          if ((match)) && ((${#existing[@]} == 0)); then
            install -m 0600 -t "${dst}" "${src}"/*.nmconnection
            # DHCP profiles carried over from the initramfs would compete
            rm -f /run/NetworkManager/system-connections/*.nmconnection
            echo "okd-pve: installed the static network configuration of the rendezvous host (the installer did not copy it)"
          fi
          touch "${done}"
systemd:
  units:
    - name: okd-pve-rendezvous-network.service
      enabled: true
      contents: |
        [Unit]
        Description=okd-pve: static network of the rendezvous host if the installer did not copy it
        ConditionPathExists=!/var/lib/okd-pve/rendezvous-network.checked
        Wants=network-pre.target
        Before=network-pre.target NetworkManager.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/bash /usr/local/bin/okd-pve-rendezvous-network.sh
        [Install]
        WantedBy=multi-user.target
