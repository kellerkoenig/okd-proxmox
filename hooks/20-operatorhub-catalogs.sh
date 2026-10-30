#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Operator catalogs for OperatorHub.
#
#   OKD_PVE_CATALOG_PROFILE=okderators  adds the OKD community catalog
#                                       (quay.io/okderators/catalog-index:<minor>)
#   OKD_PVE_CATALOG_PROFILE=redhat      enables the default redhat-operators
#                                       source. Catalogs from registry.redhat.io
#                                       need a valid Red Hat pull secret in the
#                                       cluster (openshift-config/pull-secret).
#
#   OPERATORHUB_ENABLE   additional default sources to enable (space separated,
#                        e.g. "certified-operators community-operators")
#   OKDERATORS_IMAGE     override the OKDerators catalog image
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

enable=${OPERATORHUB_ENABLE:-}
rc=0

catalog_ready() {
	[[ $(oc get catalogsource "$1" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null) == READY ]]
}

case $(catalog_profile) in
redhat)
	enable="redhat-operators ${enable}"
	if ! oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d |
		jq -e '.auths | has("registry.redhat.io")' >/dev/null; then
		echo "WARNING: the cluster pull secret has no registry.redhat.io credentials; redhat-operators cannot pull images." >&2
		echo "         Set install.pull_secret_file before create, or update openshift-config/pull-secret." >&2
		rc=2
	fi
	;;
okderators)
	minor=$(sed -E 's/^([0-9]+\.[0-9]+).*/\1/' <<<"${OKD_PVE_OKD_VERSION:-}")
	image=${OKDERATORS_IMAGE:-}
	if [[ -z ${image} ]]; then
		image=quay.io/okderators/catalog-index:latest
		if curl -fsS "https://quay.io/api/v1/repository/okderators/catalog-index/tag/?specificTag=${minor}&onlyActiveTags=true" 2>/dev/null |
			jq -e 'try (.tags | length > 0) catch false' >/dev/null 2>&1; then
			image=quay.io/okderators/catalog-index:${minor}
		fi
	fi
	apply_idempotent - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: okderators
  namespace: openshift-marketplace
spec:
  displayName: OKDerators
  publisher: OKD Community
  sourceType: grpc
  image: ${image}
  priority: -100
  updateStrategy:
    registryPoll:
      interval: 30m
  grpcPodConfig:
    securityContextConfig: restricted
    nodeSelector:
      node-role.kubernetes.io/master: ""
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
YAML
	oc_wait 600 "CatalogSource okderators (${image})" catalog_ready okderators
	echo "CatalogSource okderators ready (${image})."
	;;
*)
	echo "Profile $(catalog_profile): no catalog changes."
	;;
esac

if [[ -n ${enable// /} ]]; then
	sources=$(oc get operatorhub cluster -o json | jq -c --arg e "${enable}" '
		($e | split(" ") | map(select(. != ""))) as $en
		| (.spec.sources // []) as $s
		| ($s | map(select(.name as $n | $en | index($n) | not)))
		  + ($en | map({name: ., disabled: false}))')
	patch_merge operatorhub/cluster "{\"spec\": {\"sources\": ${sources}}}"
	for s in ${enable}; do
		oc_wait 600 "CatalogSource ${s}" catalog_ready "${s}" || rc=2
	done
fi
exit "${rc}"
