<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Hook manifests

`*.yaml` / `*.yml` files in a `manifests/` directory of a hooks source are
applied with `oc apply` as part of the hook run. They are sorted together
with the hook scripts, so number them like hooks (`60-namespaces.yaml`) to
control the order.

Built-in manifests run only when listed in `hooks.builtin`; manifests in
the external hooks directory always run. See docs/hooks.md.
