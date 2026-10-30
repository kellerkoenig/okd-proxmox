<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Security policy

## Supported versions

Security fixes go into the latest release. Please check that the problem
still exists there before you report it.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report them privately through GitHub:
**Security → Report a vulnerability** in this repository
([direct link](https://github.com/kellerkoenig/okd-proxmox/security/advisories/new)).

Helpful in a report:

- the `okd-pve version` output, the OKD and Proxmox VE versions,
- the steps to reproduce the problem,
- what an attacker could achieve, and under which preconditions.

Do not include real secrets, hostnames or addresses. Placeholders
(`example.com`, `192.0.2.0/24`) are enough to show the problem.

You can expect a first answer within a week. This is a volunteer project;
fixes are made as fast as the problem's severity requires.

## Scope

Of particular interest:

- secrets (Proxmox API token, pull secret, kubeadmin password, hook secrets)
  that appear in terminal output, log files or generated files despite the
  redaction,
- command or code injection through `cluster.yaml`, `install-config.yaml`,
  hook settings or Proxmox API responses,
- files written with permissions that are too open,
- downloads of `openshift-install`, `oc`, `tofu` or `butane` that skip or
  bypass checksum verification.

Out of scope: vulnerabilities in OKD, Proxmox VE, OpenTofu or the bpg/proxmox
provider themselves. Please report those upstream.
