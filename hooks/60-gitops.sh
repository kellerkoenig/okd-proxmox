#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# GitOps bootstrap: the GitOps operator (Argo CD) with its default instance
# openshift-gitops on the infra nodes and, when a repository is configured,
# one "app of apps" Application that points at it. From then on the
# application deployments are the GitOps repository's job, not okd-pve's.
# Without GITOPS_REPO_URL only the operator and the instance are installed.
#
# Settings (hooks.env):
#   GITOPS_REPO_URL           Git repository, https://... or git@host:path.git
#   GITOPS_REPO_PATH          path in the repository; default: clusters/<cluster name>
#   GITOPS_REVISION           branch, tag or commit; default: HEAD (the default branch)
#   GITOPS_APP_NAME           name of the bootstrap Application; default: bootstrap
#   GITOPS_AUTO_SYNC          true (default): sync automatically and undo manual
#                             changes (selfHeal); false: sync by hand
#   GITOPS_PRUNE              true: delete resources removed from Git; default: false
#   GITOPS_CLUSTER_ADMIN      true: the application controller of the default
#                             instance gets cluster-admin (Argo CD then manages
#                             namespaces, CRDs, operators); default: false, Argo CD
#                             only manages namespaces labeled
#                             argocd.argoproj.io/managed-by=openshift-gitops
#   GITOPS_REPO_CA_FILE       PEM file with the CA of an https Git server
#                             (relative to the cluster directory)
#   GITOPS_REPO_KNOWN_HOSTS   ssh: known_hosts line(s) of the Git server
#                             (ssh-keyscan <host>); Argo CD knows the big
#                             public Git hosts already
#
# Credentials only from the environment (never in cluster.yaml):
#   GITOPS_REPO_USERNAME, GITOPS_REPO_PASSWORD   https: user and password or access token
#   GITOPS_REPO_SSH_KEY_FILE                     ssh: private key file (read-only deploy key)
#
# Operator package and channel come from the catalog profile (key GITOPS,
# docs/hooks.md); pin the channel with OKD_PVE_OP_GITOPS_CHANNEL.
set -euo pipefail
# shellcheck source=../lib/oclib.sh
source "${OKD_PVE_LIB_DIR:?run via okd-pve hooks run}/oclib.sh"
# shellcheck source=../lib/catalog.sh
source "${OKD_PVE_LIB_DIR}/catalog.sh"

ns=openshift-gitops
repo=${GITOPS_REPO_URL:-}
ssh_url=0
[[ ${repo} =~ ^(ssh://|[A-Za-z0-9._-]+@) ]] && ssh_url=1

# Check the settings before installing anything.
if [[ -n ${repo} ]]; then
	if ((ssh_url)); then
		key=${GITOPS_REPO_SSH_KEY_FILE:-}
		[[ -n ${key} ]] || {
			echo "GITOPS_REPO_URL is an ssh URL, but GITOPS_REPO_SSH_KEY_FILE is not set." >&2
			exit 1
		}
		[[ ${key} == /* ]] || key=${OKD_PVE_CLUSTER_DIR}/${key}
		[[ -r ${key} ]] || {
			echo "GITOPS_REPO_SSH_KEY_FILE ${key} is not readable." >&2
			exit 1
		}
	elif [[ ${repo} != https://* && ${repo} != http://* ]]; then
		echo "GITOPS_REPO_URL must start with https://, http://, ssh:// or user@host: (got ${repo})." >&2
		exit 1
	elif [[ -n ${GITOPS_REPO_USERNAME:-} && -z ${GITOPS_REPO_PASSWORD:-} ]]; then
		echo "GITOPS_REPO_USERNAME is set, GITOPS_REPO_PASSWORD is not." >&2
		exit 1
	fi
	ca=${GITOPS_REPO_CA_FILE:-}
	if [[ -n ${ca} ]]; then
		[[ ${ca} == /* ]] || ca=${OKD_PVE_CLUSTER_DIR}/${ca}
		grep -q 'BEGIN CERTIFICATE' "${ca}" 2>/dev/null || {
			echo "GITOPS_REPO_CA_FILE ${ca} is not a PEM certificate." >&2
			exit 1
		}
	fi
fi

install_operator_by_key gitops
wait_for_crd applications.argoproj.io
wait_for_crd argocds.argoproj.io
# quiet checks for oc_wait (it reports the progress itself)
argocd_exists() { oc get argocd openshift-gitops -n "${ns}" >/dev/null 2>&1; }
rolled_out() { oc -n "${ns}" rollout status "$1" --timeout=10s >/dev/null 2>&1; }
oc_wait 900 "Argo CD instance ${ns}/openshift-gitops" argocd_exists

# Default instance on the infra nodes. The operator's GitopsService owns the
# placement; patching the Argo CD instance directly would be undone. The
# nodeSelector is set explicitly: with tolerations set, GitOps 1.22 dropped
# the infra nodeSelector that runOnInfra alone adds.
if ((${OKD_PVE_INFRA_NODE_COUNT:-0} > 0)); then
	gitopsservice() { [[ -n $(oc get gitopsservices.pipelines.openshift.io -A -o name 2>/dev/null) ]]; }
	oc_wait 300 "GitopsService cluster" gitopsservice
	gs_ns=$(oc get gitopsservices.pipelines.openshift.io -A -o jsonpath='{.items[0].metadata.namespace}')
	tol='[]'
	[[ ${OKD_PVE_INFRA_TAINTED:-false} == true ]] && tol=$(infra_tolerations_json)
	patch_merge gitopsservice/cluster "$(jq -cn --argjson tol "${tol}" '{spec: {runOnInfra: true, nodeSelector: {"node-role.kubernetes.io/infra": ""}, tolerations: $tol}}')" \
		${gs_ns:+-n "${gs_ns}"}
fi

if [[ -n ${GITOPS_REPO_KNOWN_HOSTS:-} ]]; then
	patch_merge "argocd/openshift-gitops" "$(jq -cn --arg k "${GITOPS_REPO_KNOWN_HOSTS}" \
		'{spec: {initialSSHKnownHosts: {keys: $k}}}')" -n "${ns}"
fi
if [[ -n ${repo} && -n ${ca:-} ]]; then
	host=${repo#*://}
	host=${host%%/*}
	host=${host##*@}
	host=${host%%:*}
	patch_merge "argocd/openshift-gitops" "$(jq -cn --arg h "${host}" --rawfile pem "${ca}" \
		'{spec: {tls: {initialCerts: {($h): $pem}}}}')" -n "${ns}"
fi

oc_wait 900 "Argo CD server in ${ns}" rolled_out deployment/openshift-gitops-server
# A StatefulSet does not replace a pod that never became ready: the
# application controller created before the placement patch stays Pending
# with the old spec (no toleration for the infra taint). Delete such a pod
# so that it is recreated from the current revision.
controller_rolled_out() {
	local sts=openshift-gitops-application-controller rev pod
	rolled_out "statefulset/${sts}" && return 0
	rev=$(oc -n "${ns}" get statefulset "${sts}" -o jsonpath='{.status.updateRevision}' 2>/dev/null) || return 1
	pod=$(oc -n "${ns}" get pod "${sts}-0" -o json 2>/dev/null) || return 1
	if [[ -n ${rev} ]] && jq -e --arg rev "${rev}" '.status.phase == "Pending"
		and .metadata.labels["controller-revision-hash"] != $rev' <<<"${pod}" >/dev/null; then
		echo "Recreating ${sts}-0: Pending with an outdated revision"
		oc -n "${ns}" delete pod "${sts}-0" --wait=false >/dev/null || true
	fi
	return 1
}
oc_wait 900 "Argo CD application controller in ${ns}" controller_rolled_out

if [[ ${GITOPS_CLUSTER_ADMIN:-false} == true ]]; then
	apply_idempotent - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: okd-pve-gitops-cluster-admin
  labels:
    app.kubernetes.io/managed-by: okd-pve
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: ${ns}
YAML
else
	oc delete clusterrolebinding okd-pve-gitops-cluster-admin --ignore-not-found >/dev/null
fi

url=$(oc -n "${ns}" get route openshift-gitops-server -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z ${repo} ]]; then
	echo "Argo CD is ready${url:+ at https://${url}}. No GITOPS_REPO_URL set: no bootstrap Application."
	exit 0
fi

# Repository credentials: a Secret that Argo CD picks up by its label. The
# values go straight to the API, never into a file or the output.
secret=$(jq -n --arg ns "${ns}" --arg url "${repo}" \
	--arg user "${GITOPS_REPO_USERNAME:-}" --arg pass "${GITOPS_REPO_PASSWORD:-}" \
	--rawfile key "${key:-/dev/null}" '{
	apiVersion: "v1", kind: "Secret",
	metadata: {name: "okd-pve-bootstrap-repo", namespace: $ns,
		labels: {"argocd.argoproj.io/secret-type": "repository", "app.kubernetes.io/managed-by": "okd-pve"}},
	stringData: ({type: "git", url: $url}
		+ (if $user != "" then {username: $user, password: $pass} else {} end)
		+ (if $key != "" then {sshPrivateKey: $key} else {} end))}')
apply_idempotent - <<<"${secret}"

auto=${GITOPS_AUTO_SYNC:-true}
apply_idempotent - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${GITOPS_APP_NAME:-bootstrap}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: okd-pve
spec:
  project: default
  source:
    repoURL: ${repo}
    path: ${GITOPS_REPO_PATH:-clusters/${OKD_PVE_CLUSTER_NAME}}
    targetRevision: ${GITOPS_REVISION:-HEAD}
  destination:
    server: https://kubernetes.default.svc
$(if [[ ${auto} == true ]]; then
	cat <<SYNC
  syncPolicy:
    automated:
      prune: ${GITOPS_PRUNE:-false}
      selfHeal: true
SYNC
fi)
YAML

# A repository that is not reachable or empty is not an installation
# failure: report it as a warning, Argo CD keeps retrying.
app=${GITOPS_APP_NAME:-bootstrap}
cond() { oc -n "${ns}" get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null; }
for _ in $(seq 1 18); do
	[[ $(cond) =~ ^(Synced|OutOfSync)$ ]] && break
	sleep 10
done
status=$(cond || true)
if [[ ${status} =~ ^(Synced|OutOfSync)$ ]]; then
	echo "Application ${app}: ${status}, repository ${repo}${url:+; Argo CD at https://${url}}."
	exit 0
fi
msg=$(oc -n "${ns}" get application "${app}" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || true)
echo "Application ${app} could not read ${repo} yet: ${msg:-no status}" >&2
exit 2
