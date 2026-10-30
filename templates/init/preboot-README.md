<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Pre-Boot manifests

Files in this directory are added to the agent ISO and take effect at the
first boot of every node: no reboots, unlike the same change applied after
installation.

- `*.bu` Butane files are rendered with `butane` (use `variant: openshift`).
  Files referenced with `local:` are looked up in this directory.
- `*.yaml` / `*.yml` manifests are copied unchanged.
- A file with the same name as a built-in manifest (e.g.
  `99-worker-okd-pve-chrony.yaml`) replaces it.

Rule of thumb: everything that creates a MachineConfig or KubeletConfig
belongs here. See docs/preboot-vs-post-install.md in the okd-pve repository.
