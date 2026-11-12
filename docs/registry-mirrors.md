<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Copyright (C) 2026 The okd-proxmox Authors -->
# Registry mirrors

A registry mirror in this document is a pull-through cache, such as an
Artifactory or Nexus remote repository or a Harbor proxy project. With a
mirror, the nodes pull images from your local cache instead of the
internet. Rebuilds are faster and need no internet access for images,
and rate limits no longer apply. Mirrors are optional; without
`registry_mirrors`, nothing changes.

## Which registries OKD needs

| Source | What comes from there |
|---|---|
| `quay.io` | OKD release and payload images (`quay.io/okd/scos-release`, `scos-content`), the OKDerators catalog, some hook images |
| `registry.redhat.io` | Red Hat operator catalogs and operator images (catalog profile `redhat`) |
| `registry.access.redhat.com` | UBI images, e.g. the storage test pod |
| `registry.connect.redhat.com` | certified operators (`certified-operators` catalog) |

Sources without a mirror are pulled directly, as before. Storage backends
and your own hooks may need more (`registry.k8s.io`, `ghcr.io`, ...).

## Configuration

```yaml
# cluster.yaml
registry_mirrors:
  fallback: false                   # nodes pull only from the mirrors
  username: svc-okd                 # credentials, see below
  password: ""                      # or OKD_PVE_MIRROR_PASSWORD
  registries:
    - {source: quay.io,                     mirror: quay-cache.example.com}
    - {source: registry.redhat.io,          mirror: redhat-cache.example.com}
    - {source: registry.access.redhat.com,  mirror: redhat-access-cache.example.com}
    - {source: registry.connect.redhat.com, mirror: redhat-connect-cache.example.com, fallback: true}
```

| Key | Default | Meaning |
|---|---|---|
| `source` | – | registry host with optional port and path (`quay.io`, `quay.io/okd`, `*.example.com`), no `https://` |
| `mirror` | – | host with optional port and path that serves the same repositories: `quay.io/okd/scos-release` becomes `<mirror>/okd/scos-release` |
| `fallback` | `false` | `false`: never contact the source (`NeverContactSource`); an image that the mirror cannot deliver fails to pull. `true`: try the mirror first, then the source. Set it globally or per entry. |
| `username`, `password` | `""` | one login for every mirror; an entry can set its own `username`/`password`. `$OKD_PVE_MIRROR_PASSWORD` overrides `password` (not an entry's own). Empty for anonymous mirrors |
| `auth_file` | `""` | alternatively or in addition: auth.json (`podman login --authfile`) with credentials per mirror host |

Without fallback the mirror must deliver every image of that source. Run
`okd-pve preflight` first: it checks every mirror host from your
workstation.

**During the installation the nodes may still contact the source.** The
agent installer drops the policy when it creates the cluster's
ImageDigestMirrorSet, and the MCO refuses different policies for the same
source in the ImageDigestMirrorSet and the ImageTagMirrorSet ("conflicting
mirrorSourcePolicy"): the bootstrap machine-config-controller crashes, the
Machine Config Server never starts and the other masters wait forever for
`https://<api-vip>:22623/config/master`. So okd-pve installs both sets
without policy (mirror first, then the source), and `create` sets
`NeverContactSource` on both after the installation (step 11). As long as
the mirror delivers, every image comes from the mirror anyway; the source
is only contacted when the mirror fails.

### Credentials

When one user may read every mirror (typical for Artifactory), set it once:

```yaml
registry_mirrors:
  username: svc-okd
  password: "..."                   # or leave it empty and export OKD_PVE_MIRROR_PASSWORD
```

`okd-pve` writes an entry `<mirror>: {auth: base64(user:password)}` for
every mirror into the pull secret. Where the password comes from, first
match wins:

1. `password` of the entry in `registries`
2. `$OKD_PVE_MIRROR_PASSWORD`
3. `registry_mirrors.password`

The user name comes from the entry, else from `registry_mirrors.username`.
A password in `cluster.yaml` is masked in all output and logs; keep the
file private (mode 600, `preflight` warns otherwise). With
`OKD_PVE_MIRROR_PASSWORD` it stays out of the file, but every command that
renders the pull secret (`create`, `preflight`, `mirrors apply`) needs the
variable.

Different credentials per mirror host can also come from an auth.json
(with subdomain access in Artifactory, every repository is a host of its
own):

```bash
cd clusters/<name>
podman login --authfile mirror-auth.json quay-cache.example.com
chmod 600 mirror-auth.json
# cluster.yaml: registry_mirrors.auth_file: mirror-auth.json
```

For the same mirror, `username`/`password` win over `auth_file`. Your Red
Hat pull secret (`pull-secret.json`) stays unchanged. Use a technical user,
because its credentials end up in the cluster's global pull secret.

### Certificate

The nodes must trust the mirror's TLS certificate, both in the live ISO
during installation and in the cluster. Put the issuing CA into
`additionalTrustBundle` in `install-config.yaml`. Without a proxy, also
set `additionalTrustBundlePolicy: Always`, because the default `Proxyonly`
ignores the bundle when no proxy is configured.

## What okd-pve does

On `create`, the mirrors are Pre-Boot, so no node reboots for them later:

| Where | What |
|---|---|
| generated `install-config.yaml` | `imageDigestSources` without `sourcePolicy` (see above). The agent installer puts them into the live ISO and creates the ImageDigestMirrorSet `image-digest-mirror`, used for images pulled by digest (release payload). Entries you already have in `install-config.yaml` are kept. When a mirror covers `quay.io` (or `quay.io/okd`), okd-pve adds exact entries for `quay.io/okd/scos-release` and `quay.io/okd/scos-content` with the same mirror: `openshift-install` only recognizes a release mirror whose source names the release repository exactly (otherwise it warns "should have at least one source field matching the releaseImage"). |
| extra manifest | ImageTagMirrorSet `image-tag-mirror` without policy, used for images pulled by tag (catalogs, hook and storage images) |
| after the installation (step 11) | the `mirrorSourcePolicy` from `fallback` on both sets, in one `oc apply`, like `okd-pve mirrors apply`; then `create` waits for the MachineConfigPools (no reboot; the MCO may drain the nodes one at a time) |
| `proxy.noProxy` | mirror hosts that `noProxy` does not cover yet are appended, when a proxy is set |
| `pullSecret` | the mirror credentials (`username`/`password`, `auth_file`) |

`node add` needs nothing extra: `oc adm node-image create` copies the
cluster's mirror configuration into the node ISO.

`preflight` checks every mirror host for an answer on `/v2/`, for
credentials if it asks for them, and whether it accepts them. A problem
with a mirror without fallback is a `FAIL`, with fallback a `WARN`.
`verify` warns when the cluster lacks a configured mirror, or when a mirror
without fallback has no `NeverContactSource` in the cluster.

## Running clusters

```bash
okd-pve mirrors apply --dry-run     # show what would change
okd-pve mirrors apply
```

The command first runs the preflight checks for the mirrors, then:

- adds the mirror credentials to `openshift-config/pull-secret`,
- creates or updates `image-digest-mirror` and `image-tag-mirror` with
  the policy from `fallback` (both in one `oc apply`, so the MCO never
  sees different policies for the same source), or deletes them when
  `registries` is empty,
- waits for the MachineConfigPools. The MCO writes `registries.conf` and
  the pull secret on every node and reloads CRI-O; it never reboots. Digest
  mirrors and the pull secret need no drain. New tag mirrors (and removed
  mirrors or a changed `fallback`) make the MCO drain the nodes one at a
  time first, so pods move once.

It does not change `proxy/cluster`, because a new `noProxy` makes the MCO
reboot every node. When a mirror host is missing from the cluster's
`noProxy`, it warns. That is fine as long as the proxy can reach the mirror.

## Testing a mirror by hand

```bash
podman login quay-cache.example.com
podman pull quay-cache.example.com/okd/scos-release:4.21.0-okd-scos.11
podman pull redhat-access-cache.example.com/ubi9/ubi-minimal:latest
```

On a node: `oc debug node/<name> -- chroot /host cat /etc/containers/registries.conf`.

## Artifactory

- One remote repository of type Docker per source, with the source URL
  (`https://quay.io`, `https://registry.redhat.io`, ...). For
  `registry.redhat.io` and `registry.connect.redhat.com`, give Artifactory
  the credentials of a Red Hat registry service account.
- Subdomain access: `mirror: <repo-key>.<artifactory-host>`. Repository
  path access: `mirror: <artifactory-host>/<repo-key>`.
- On a cache miss Artifactory fetches the image from the source first. The
  first installation through an empty cache is therefore not faster than
  one without a mirror; every rebuild after that is.
