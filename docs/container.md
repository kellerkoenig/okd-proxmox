<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Container image

`ghcr.io/kellerkoenig/okd-proxmox:<version>` (also on Docker Hub as
`docker.io/kellerkoenig/okd-proxmox`) contains `okd-pve` and every
tool it needs: bash, curl, jq, yq, nmstatectl, ssh/scp, whiptail, dig. You
need nothing but **docker or podman**; both work the same way.
`oc`, `openshift-install`, `tofu` and `butane` depend on the cluster's OKD
version; `okd-pve` downloads them into `<cluster>/bin` on first use, as it
does without the container.

Every release pushes `<version>` and `latest` to both registries, the same
image (same digest) with a signed build provenance:

```bash
gh attestation verify oci://ghcr.io/kellerkoenig/okd-proxmox:0.2.0 --repo kellerkoenig/okd-proxmox
gh attestation verify oci://index.docker.io/kellerkoenig/okd-proxmox:0.2.0 --repo kellerkoenig/okd-proxmox
```

Prefer ghcr.io: Docker Hub limits anonymous pulls to a few per hour and IP
address, which a CI pipeline or a team behind one NAT address reaches
quickly. The examples below use ghcr.io; `docker.io/kellerkoenig/okd-proxmox`
works the same way.

## Usage

The container works in `/work`; mount the directory that holds `clusters/`
there, and your `~/.ssh` (read-only) to `/home/okd-pve/.ssh`:

```bash
# docker
docker run --rm -it \
  -v "$PWD:/work:Z" \
  -v "$HOME/.ssh:/home/okd-pve/.ssh:ro,Z" \
  -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
  ghcr.io/kellerkoenig/okd-proxmox:0.2.0 --dir clusters/lab create

# podman: the same command
podman run --rm -it \
  -v "$PWD:/work:Z" \
  -v "$HOME/.ssh:/home/okd-pve/.ssh:ro,Z" \
  -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
  ghcr.io/kellerkoenig/okd-proxmox:0.2.0 --dir clusters/lab create
```

An alias makes it feel like the local script (replace `docker` with
`podman` if you use that):

```bash
alias okd-pve='docker run --rm -it -v "$PWD:/work:Z" -v "$HOME/.ssh:/home/okd-pve/.ssh:ro,Z" -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY ghcr.io/kellerkoenig/okd-proxmox:0.2.0'
okd-pve init lab
okd-pve preflight
okd-pve create
okd-pve status
```

### What the options do

| Option | Why |
|---|---|
| `-v "$PWD:/work:Z"` | the directory with `clusters/`. Everything `okd-pve` writes (state, logs, kubeconfig, tool downloads, etcd backups) lands there. `:Z` relabels it for SELinux hosts (Fedora, RHEL); without SELinux it does nothing. |
| `-v "$HOME/.ssh:/home/okd-pve/.ssh:ro,Z"` | the public key for the nodes (`install-config.yaml` `sshKey`, if not set there) and the private key that `etcd restore` uses |
| `-e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY` | passes your proxy settings from the shell. podman does that by default, docker only with these options (or a proxy in `~/.docker/config.json`). Harmless without a proxy. |
| `-it` | questions (`destroy`, `etcd restore`) and `okd-pve tui` need a terminal. With `--yes` and no TUI, `--rm` alone is enough, for example in CI. |

### File ownership

The entrypoint runs `okd-pve` as the owner of `/work`, so the files belong
to you on the host:

- **docker** starts the container as root; the entrypoint creates a user
  with the uid and gid of `/work` and runs `okd-pve` as that user. Do not
  pass `--user`: ssh needs the user the entrypoint creates.
- **podman** (rootless) maps root in the container to your user;
  `okd-pve` runs as root in the container, which is you on the host.

`HOME` is `/home/okd-pve` in both cases. Caches (base ISO, OpenTofu
providers) go to `/work/.cache` unless `proxmox.cache_dir` is set.

### Secrets

Credentials from the environment (hook settings such as
`ALERTMANAGER_WEBHOOK_URL`, `GITOPS_REPO_PASSWORD`, or
`PROXMOX_VE_API_TOKEN` instead of `proxmox.conf`): pass them with
`-e NAME` (the value comes from your shell), never with `-e NAME=value` on
the command line, where it ends up in the shell history and the process
list. Instead of mounting `~/.ssh`, you can point
`-e OKD_PVE_SSH_PUBLIC_KEY_FILE=...` and `-e OKD_PVE_SSH_PRIVATE_KEY_FILE=...`
to keys inside the mounted directory.

## Building it yourself

```bash
docker build -f Containerfile --build-arg OKD_PVE_VERSION=dev -t okd-pve:dev .
podman build -f Containerfile --build-arg OKD_PVE_VERSION=dev -t okd-pve:dev .
```

The base image is pinned by digest, yq by version and SHA256; Renovate
proposes updates for both. CI builds the image with docker on every pull
request.
