<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Post-Install hooks

Hooks configure the running cluster after the installation: operators,
ingress, monitoring, OAuth, everything the API can do. `create` runs them as
its last step; `okd-pve hooks run` runs them again at any time.

## Two sources

1. **Built-in examples** in [hooks/](../hooks/) of this repository. They are
   generic, contain no environment data and run only when listed in
   `hooks.builtin` in `cluster.yaml` (or `builtin: all`).
2. **Your private hooks directory**, set with `--hooks-dir` or `hooks.dir`
   (relative paths are relative to the cluster directory). This is where
   environment-specific hooks live: real URLs, identity providers,
   inventory integration. It is a separate repository and never part of
   this one.

Both are merged and sorted by name. If both contain the same file name, the
private one wins, which lets you replace a built-in hook. `hooks.skip`
removes hooks from either source.

## Mechanics

- A hook is an **executable file whose name starts with a number**:
  `10-...`, `20-...`. Non-executable files and files without a number are
  ignored, so `*.example` files are inert.
- `manifests/*.yaml` (and `.yml`) in either source are applied with
  `oc apply` and sorted together with the scripts: `25-namespaces.yaml`
  runs between `20-...` and `30-...`.
- Hooks run in lexical order, each with a timeout (`hooks.timeout`, default
  3600 s).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | success |
| `2` | warning: reported, the run continues |
| anything else | failure: the run stops, `okd-pve` exits with `4` |

At the end you get a **hook report**: every hook, its source, duration and
result, including the hooks that were not run. Fix a failed hook and
continue with:

```bash
okd-pve hooks run --from 40-monitoring   # this hook and all after it
okd-pve hooks run 40-monitoring          # only this one ("40-monitoring.sh", "monitoring" work too)
okd-pve hooks list                       # all hooks with their last result
okd-pve --dry-run hooks run              # what would run
```

### Environment

| Variable | Content |
|---|---|
| `KUBECONFIG` | cluster admin kubeconfig |
| `OKD_PVE_CLUSTER_NAME`, `OKD_PVE_BASE_DOMAIN` | from install-config.yaml |
| `OKD_PVE_CLUSTER_DIR` | cluster directory |
| `OKD_PVE_STORAGE_CLASS` | `monitoring.storage_class` (falls back to `storage.storage_class`) |
| `OKD_PVE_INFRA_TAINT_KEY`, `OKD_PVE_INFRA_TAINT_VALUE`, `OKD_PVE_INFRA_TAINT_EFFECTS` | infra taint from cluster.yaml |
| `OKD_PVE_INFRA_NODES`, `OKD_PVE_INFRA_NODE_COUNT`, `OKD_PVE_INFRA_TAINTED` | infra nodes |
| `OKD_PVE_OKD_VERSION` | OKD release |
| `OKD_PVE_LIB_DIR` | `lib/` of okd-pve, for `oclib.sh` and `catalog.sh` |
| `OKD_PVE_BIN` | path of `okd-pve` |
| `OKD_PVE_HOOK_NAME`, `OKD_PVE_DRY_RUN`, `OKD_PVE_DEBUG` | |
| everything from `hooks.env` | non-secret settings, see each hook's header |

Real environment variables win over `hooks.env`. Secrets (webhook URLs,
OAuth client secrets, tokens) must come from the environment, e.g. exported
from your secret store before `okd-pve create`, and never from a file in a
repository.

## Helper library: lib/oclib.sh

Hooks should use these functions instead of writing their own wait loops:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "${OKD_PVE_LIB_DIR}/oclib.sh"
source "${OKD_PVE_LIB_DIR}/catalog.sh"   # only for install_operator_by_key
```

| Function | What it does |
|---|---|
| `wait_for_cluster_operators [timeout]` | all ClusterOperators `Available=True`, `Degraded=False`, `Progressing=False` |
| `wait_for_mcp <pool> [timeout]` | MachineConfigPool `Updated`, not `Degraded`, all machines updated. Call it after every MachineConfig you apply after the installation. |
| `install_operator <package> <channel> <namespace> [source] [source-ns]` | namespace + OperatorGroup if needed (install mode from the operator's CSV), Subscription, waits for the CSV `Succeeded` **and for every CRD the CSV owns**. Without the CRD wait, applying the custom resource right after the subscription fails, which is where hand-written runbooks usually break. Channel `@default` uses the catalog's default channel. |
| `install_operator_by_key <key>` | same, with package/channel/namespace/source from the catalog profile (below) |
| `wait_for_crd <name> [timeout]` | CRD established |
| `sa_token <sa> <namespace> [--duration D \| --long-lived]` | token via `oc create token` (time-bound, default) or a `kubernetes.io/service-account-token` Secret (long-lived). Do not use `oc serviceaccounts get-token` (removed with OCP 4.11) or `oc describe sa`: service accounts no longer get token secrets automatically. |
| `apply_idempotent [file\|dir\|-]` | always `oc apply`, never `oc create`, so hooks can run again |
| `patch_merge <resource> <json> [oc args]` | merge patch only when the live object differs; reports "patched" or does nothing |
| `node_set_label`, `node_set_taint`, `node_has_taint`, ... | idempotent node helpers |
| `infra_tolerations_json` | tolerations for the configured infra taint |
| `oc_wait <timeout> <description> <cmd...>` | generic polling with progress output |

### Operator catalogs (lib/catalog.sh)

`OKD_PVE_CATALOG_PROFILE` (in `hooks.env`) selects where operators come
from:

| Profile | Catalog | Notes |
|---|---|---|
| `okderators` (default) | `okderators` CatalogSource (`quay.io/okderators/catalog-index:<minor>`), added by hook 20 | OKD community builds; no ClusterResourceOverride |
| `redhat` | `redhat-operators` | needs a Red Hat pull secret (`install.pull_secret_file`) for registry.redhat.io |

Override any single value: `OKD_PVE_OP_<KEY>_PACKAGE`, `_CHANNEL`,
`_NAMESPACE`, `_SOURCE`, with key e.g. `LOGGING`, `DESCHEDULER`,
`CERT_MANAGER`, `WEB_TERMINAL`, `CLUSTER_RESOURCE_OVERRIDE`,
`LOCAL_STORAGE`, `ODF`, `GITOPS`. Pin channels for reproducible operator
versions; `@default` follows the catalog.

## Built-in example hooks

| Hook | Does |
|---|---|
| `10-infra-nodes` | infra labels/taints from cluster.yaml (`okd-pve node reconcile`) |
| `15-scc-anyuid-nfs` | adds `nfs` to the `anyuid` SCC volumes, idempotently |
| `20-operatorhub-catalogs` | OKDerators catalog or `redhat-operators`; warns if registry.redhat.io credentials are missing |
| `30-ingress-controller` | replicas, placement on infra nodes with tolerations, `headerBufferBytes`, HTTP/2 |
| `35-image-registry` | enables the internal registry on a PVC, placed on infra |
| `40-monitoring` | `cluster-monitoring-config` + `user-workload-monitoring-config`: retention, PVCs, placement, user AlertmanagerConfig, requests of the user workload Prometheus. Skips components that do not exist in this OKD version. |
| `45-alertmanager-receiver` | Slack/Mattermost (or plain webhook) receiver with a separate route for critical alerts; URL and proxy only from the environment |
| `50-operator-logging` | Logging operator + collector service account |
| `51-operator-descheduler` | Kube Descheduler with interval, profiles, `podLifetime` |
| `52-operator-cluster-resource-override` | ClusterResourceOverride with CPU/memory percentages; `CRO_LIMIT_CPU_TO_MEMORY_PERCENT=0` leaves CPU limits alone |
| `53-operator-cert-manager` | cert-manager operator + `CertManager` |
| `54-operator-web-terminal` | Web Terminal + idle timeout |
| `55-eventrouter` | event router (plain manifests, no operator exists) |
| `80-oauth-oidc.sh.example` | pattern: OIDC identity provider |
| `81-inventory-serviceaccount.sh.example` | pattern: read-only service account + token for an inventory |
| `82-gitops-bootstrap.sh.example` | pattern: GitOps operator + bootstrap Application |
| `83-grafana-datasource-token.sh.example` | pattern: `cluster-monitoring-view` service account + long-lived token for an external Grafana (Thanos Querier data source) |

Each hook documents its settings in its header.

## Building a private hooks directory

```text
private-hooks/                 # its own (private) git repository
├── 45-alertmanager-receiver.sh   # replaces the built-in one (same name)
├── 60-oauth.sh                   # copied from 80-oauth-oidc.sh.example, adapted
├── 70-inventory.sh
├── manifests/
│   ├── 65-namespaces.yaml
│   └── 66-quotas.yaml
└── env.example                   # documents the variables your hooks need
```

```yaml
# cluster.yaml
hooks:
  dir: ../../private-hooks
  builtin: [10-infra-nodes, 20-operatorhub-catalogs, 30-ingress-controller, 40-monitoring]
```

```bash
# secrets from your secret store, never from git
export ALERTMANAGER_WEBHOOK_URL=$(pass show okd/alertmanager-webhook)
export OIDC_CLIENT_SECRET=$(pass show okd/oidc-secret)
okd-pve create
```

Values of variables whose name contains `WEBHOOK`, `SECRET`, `TOKEN` or
`PASSWORD` are masked in okd-pve's output and log files, whether they come
from the environment or from `hooks.env`. Setting such a value in
`hooks.env` is fine for a cluster directory that never leaves your machine
(it is gitignored); keep `cluster.yaml` at mode 600 then.

A minimal hook:

```bash
#!/usr/bin/env bash
# 65-example-namespace.sh: namespace with a quota (idempotent)
set -euo pipefail
source "${OKD_PVE_LIB_DIR}/oclib.sh"

apply_idempotent - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: example-apps
YAML
patch_merge namespace/example-apps '{"metadata":{"labels":{"team":"example"}}}'
```

Rules for good hooks: idempotent (`apply_idempotent`, `patch_merge`), wait
with the helpers rather than `sleep`, exit `2` for "skipped, but not
fatal", and keep application configuration out (see the scope note in the
README).
