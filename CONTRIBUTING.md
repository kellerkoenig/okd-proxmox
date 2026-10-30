<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Contributing

Thank you for helping with `okd-pve`. Bug reports, documentation fixes and
pull requests are all welcome.

## Before you start

- **Bugs and ideas:** open an issue first, so we can agree on the approach
  before you spend time on code.
- **Security problems:** never in a public issue, see [SECURITY.md](SECURITY.md).
- **Scope:** `okd-pve` builds and configures the *platform*. Application
  deployments and configuration inside operators belong to your deployment
  automation (see "Scope" in the [README](README.md)).

## Development setup

```bash
make tools   # pinned dev tools into .tools/ (nothing system-wide)
make check   # shellcheck, shfmt, bats, tofu validate + tflint, leak check
```

You need bash ≥ 4.4, curl, jq, unzip and shellcheck from your distribution.
No Proxmox or OKD is required: the tests mock the Proxmox API, `oc`,
`openshift-install` and `tofu`.

## Rules for changes

- **Bash** with `set -euo pipefail`, shellcheck- and shfmt-clean
  (`make fmt-fix` formats). Match the style of the surrounding code.
- **Tests:** every behavior change comes with a bats test in `test/`.
- **Documentation:** update the README or `docs/` in the same pull request.
  All repository content is in English.
- **No real data:** no real hostnames, domains, IP addresses, webhook URLs,
  tokens or pull secrets, not even in tests or examples. Use `example.com`
  and RFC 5737 addresses (`192.0.2.0/24`). `make leakcheck` enforces this.
  Public services the tool links to go into `.leakcheck-allow`.
- **Secrets** must never reach terminal output or log files. Use the
  redaction helpers in `lib/common.sh` (`redact_register`, `run_visible`).
<!-- REUSE-IgnoreStart -->
- **License headers:** new files start with
  `SPDX-License-Identifier: AGPL-3.0-or-later` and
  `Copyright (C) <year> The okd-proxmox Authors` in the file's comment
  syntax. Files without comment syntax go into `REUSE.toml`. CI checks this
  with [REUSE](https://reuse.software).
<!-- REUSE-IgnoreEnd -->
- **Hooks** in `hooks/` stay generic. Environment-specific hooks belong in
  your own hooks directory (`hooks.dir`).

## Pull requests

- One topic per pull request, with a short description of *why*.
- Commit messages: `area: what changed`, e.g.
  `preflight: skip the space check for existing VMs`.
- CI must be green: the same checks as `make check`, plus REUSE.

By contributing you agree that your contribution is licensed under
AGPL-3.0-or-later.
