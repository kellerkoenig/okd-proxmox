# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# CSI / storage backends (okd-pve storage install):
#   proxmox-csi    sergelogvinov/proxmox-csi-plugin with its own Proxmox token
#   ceph-external  ceph-csi RBD against a Ceph cluster outside OKD (e.g. the
#                  Ceph of the Proxmox hosts)
#   lso            Local Storage Operator on the raw data disks, optional ODF
#   nfs            nfs-subdir-external-provisioner on an existing export
#
# Every backend ends with a StorageClass, an optional "-retain" twin with
# reclaimPolicy Retain, an optional default annotation and a test PVC.

# Globals defined here are used by the other libraries and okd-pve.
# shellcheck disable=SC2034

[[ -n ${_OKD_PVE_STORAGE_LOADED:-} ]] && return 0
_OKD_PVE_STORAGE_LOADED=1

STORAGE_MANIFESTS=''
# StorageClass to use after the backend ran (ODF replaces the LSO class).
STORAGE_SC=''

# storage_emit <yaml>: queue a manifest (applied or printed for dry-run).
storage_emit() {
	local f
	f=$(printf '%s/%03d.yaml' "${STORAGE_MANIFESTS}" "$(find "${STORAGE_MANIFESTS}" -type f | wc -l)")
	cat >"${f}"
}

storage_apply_queued() {
	local f
	for f in "${STORAGE_MANIFESTS}"/*.yaml; do
		[[ -f ${f} ]] || continue
		if ((DRY_RUN)); then
			yq -N '"      " + .kind + "/" + .metadata.name + (.metadata.namespace // "" | select(. != "") | " -n " + .)' "${f}" |
				sed 's/^/    [dry-run] would apply /'
		else
			run_logged oc apply -f "${f}" || die "${EXIT_ERROR}" "Applying ${f##*/} failed." "See ${LOG_FILE}."
		fi
	done
	rm -f "${STORAGE_MANIFESTS}"/*.yaml
}

infra_tolerations_flow() {
	OKD_PVE_INFRA_TAINT_KEY=$(cfg '.infra.taint_key') \
	OKD_PVE_INFRA_TAINT_VALUE=$(cfg '.infra.taint_value') \
	OKD_PVE_INFRA_TAINT_EFFECTS=$(cfg '.infra.taint_effects' | paste -sd' ' -) \
		infra_tolerations_json
}

# storage_load_secret_file <file>: source a 0600 credentials file.
storage_load_secret_file() {
	local f=$1 mode
	[[ -f ${f} ]] || return 0
	mode=$(file_mode "${f}")
	(((8#${mode} & 8#077) == 0)) || die "${EXIT_CONFIG}" "${f} is accessible by group/others (mode ${mode})." "chmod 600 ${f}"
	# shellcheck disable=SC1090
	source "${f}"
}

cmd_storage_install() {
	local backend
	backend=$(cfg '.storage.backend')
	[[ ${backend} != none ]] || die "${EXIT_CONFIG}" "storage.backend is 'none'." \
		"Set storage.backend in cluster.yaml (proxmox-csi, ceph-external, lso or nfs)."
	if ((DRY_RUN)) && [[ ! -f ${KUBECONFIG_FILE} ]]; then
		local sc
		sc=$(cfg '.storage.storage_class')
		dry_run_note "would install storage backend ${backend} with StorageClass ${sc}$(
			[[ $(jq -r '.storage.retain_class' "${CONFIG_JSON}") == true ]] && printf ' (+ %s-retain)' "${sc}"
		)$([[ $(jq -r '.storage.default' "${CONFIG_JSON}") == true ]] && printf ', as default class')"
		return 0
	fi
	cluster_api_init
	hook_env_setup
	STORAGE_MANIFESTS=$(mktemp -d "${OKD_PVE_TMP}/storage.XXXXXX")
	log_step "Installing storage backend ${backend}"
	local sc
	sc=$(cfg '.storage.storage_class')
	case ${backend} in
	proxmox-csi) storage_proxmox_csi "${sc}" ;;
	ceph-external) storage_ceph "${sc}" ;;
	lso)
		storage_lso "${sc}"
		sc=${STORAGE_SC}
		;;
	nfs) storage_nfs "${sc}" ;;
	esac
	storage_finish "${sc}" "${backend}"
}

# storage_finish <sc> <backend>: retain twin, default class, test.
storage_finish() {
	local sc=$1 backend=$2
	if [[ $(jq -r '.storage.retain_class' "${CONFIG_JSON}") == true ]]; then
		if [[ ${backend} == lso && ${sc} == "$(cfg '.storage.storage_class')" ]]; then
			log_warn "No -retain StorageClass for the Local Storage Operator: it binds pre-created local PVs, a second class would get none."
		elif ((DRY_RUN)); then
			dry_run_note "would create StorageClass ${sc}-retain (reclaimPolicy Retain)"
		else
			oc get storageclass "${sc}" -o json | jq --arg n "${sc}-retain" '
				{apiVersion, kind, metadata: {name: $n, labels: {"okd-pve/managed": "true"}},
				 provisioner, parameters, allowVolumeExpansion, volumeBindingMode, mountOptions,
				 reclaimPolicy: "Retain"} | with_entries(select(.value != null))' | oc apply -f - >/dev/null
			log_ok "StorageClass ${sc}-retain (reclaimPolicy Retain) for data that must survive PVC deletion"
		fi
	fi
	if [[ $(jq -r '.storage.default' "${CONFIG_JSON}") == true ]]; then
		storage_set_default "${sc}"
		log_hint "Note: with a default StorageClass, PVCs meant to bind pre-created (e.g. NFS) PVs get dynamically provisioned instead. Set storageClassName: \"\" in such PVCs."
	fi
	if [[ $(jq -r '.storage.test' "${CONFIG_JSON}") == true ]]; then
		if dry_run_note "would verify ${sc} with a test PVC and delete it afterwards"; then
			return 0
		fi
		log_info "Testing ${sc} with a 1Gi PVC"
		storage_test_pvc "${sc}" || die "${EXIT_ERROR}" "The test PVC on ${sc} did not work." \
			"Check the CSI pods ('oc get pods -A | grep -i csi') and ${LOG_FILE}."
		log_ok "StorageClass ${sc} provisions, attaches and mounts volumes"
	fi
}

storage_set_default() {
	local sc=$1 other
	if dry_run_note "would mark ${sc} as default StorageClass"; then
		return 0
	fi
	for other in $(oc get storageclass -o json | jq -r --arg sc "${sc}" '.items[]
		| select(.metadata.name != $sc and .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
		| .metadata.name'); do
		oc annotate storageclass "${other}" storageclass.kubernetes.io/is-default-class- >/dev/null
		log_info "Removed default flag from StorageClass ${other}"
	done
	oc annotate storageclass "${sc}" storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
	log_ok "${sc} is the default StorageClass"
}

# storage_test_pvc <sc>: provision, mount and write a 1Gi volume, clean up.
storage_test_pvc() {
	local sc=$1 ns=okd-pve-storage-test rc=0
	oc delete namespace "${ns}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	TPL=([NAMESPACE]=${ns} [STORAGE_CLASS]=${sc} [IMAGE]=$(cfg '.storage.test_image')
	[TOLERATIONS]=$(infra_tolerations_flow))
	render_template "${OKD_PVE_ROOT}/templates/storage/storage-test.yaml.tpl" | oc apply -f - >/dev/null || rc=1
	if ((rc == 0)); then
		local phase start=${SECONDS}
		while :; do
			phase=$(oc get pod okd-pve-test -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
			[[ ${phase} == Succeeded ]] && break
			if [[ ${phase} == Failed ]] || ((SECONDS - start > 300)); then
				oc describe pvc,pod -n "${ns}" 2>&1 | redact_stream --log "${LOG_FILE}"
				rc=1
				break
			fi
			sleep 5
		done
	fi
	oc delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
	return "${rc}"
}

storage_ensure_namespace() {
	storage_emit <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
EOF
}

# storage_scc_binding <namespace> <serviceaccount> <scc>
storage_scc_binding() {
	storage_emit <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $2-scc-$3
  namespace: $1
subjects:
  - kind: ServiceAccount
    name: $2
    namespace: $1
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:$3
  apiGroup: rbac.authorization.k8s.io
EOF
}

# storage_fetch_manifest <url> <namespace>: download an upstream manifest and
# move namespaced objects (and binding subjects) into <namespace>.
storage_fetch_manifest() {
	local url=$1 ns=$2 tmp
	tmp=$(mktemp "${OKD_PVE_TMP}/upstream.XXXXXX")
	fetch "${url}" "${tmp}"
	NS=${ns} yq '
		select(.kind != "Namespace")
		| (select(.kind | test("^(ClusterRole|ClusterRoleBinding|CSIDriver|StorageClass)$") | not) | .metadata.namespace) = strenv(NS)
		| (.subjects[]? | select(.kind == "ServiceAccount") | .namespace) = strenv(NS)
	' "${tmp}" | storage_emit
}

# ---------------------------------------------------------------------------
# Proxmox CSI
# ---------------------------------------------------------------------------

storage_proxmox_csi() {
	local sc=$1 ver ns=csi-proxmox region pstorage
	ver=$(cfg '.storage.proxmox_csi.version')
	region=$(cfg '.storage.proxmox_csi.region')
	region=${region:-${CLUSTER_NAME}}
	pstorage=$(cfg '.storage.proxmox_csi.storage')
	pstorage=${pstorage:-$(cfg '.proxmox.vm_storage')}

	storage_load_secret_file "${CLUSTER_DIR}/proxmox-csi.conf"
	local token=${PROXMOX_CSI_TOKEN:-} endpoint=${PROXMOX_CSI_ENDPOINT:-${PROXMOX_VE_ENDPOINT:-}}
	local insecure=${PROXMOX_CSI_INSECURE:-${PROXMOX_VE_INSECURE:-false}}
	[[ -n ${token} ]] || die "${EXIT_CONFIG}" "PROXMOX_CSI_TOKEN is not set." \
		"Create a separate CSI token (docs/proxmox-permissions.md) and put PROXMOX_CSI_TOKEN=user@realm!id=secret into ${CLUSTER_DIR}/proxmox-csi.conf (mode 600)."
	redact_register "${token}" "${token#*=}"
	[[ ${token} =~ ^[^!@[:space:]]+@[^!@[:space:]]+![^=[:space:]]+=[^[:space:]]+$ ]] ||
		die "${EXIT_CONFIG}" "PROXMOX_CSI_TOKEN has the wrong format." "Expected user@realm!tokenid=secret."
	[[ -n ${endpoint} ]] || die "${EXIT_CONFIG}" "No Proxmox endpoint for the CSI driver." "Set PROXMOX_CSI_ENDPOINT or PROXMOX_VE_ENDPOINT."
	if [[ -n ${PROXMOX_VE_API_TOKEN:-} && ${token%%=*} == "${PROXMOX_VE_API_TOKEN%%=*}" ]]; then
		die "${EXIT_CONFIG}" "The CSI driver must not use the installer token (${token%%=*})." \
			"Create a separate token with the CSI role (docs/proxmox-permissions.md)."
	fi

	storage_ensure_namespace "${ns}"
	log_info "Proxmox CSI ${ver}: upstream manifest, credentials secret, topology labels"
	storage_fetch_manifest \
		"https://raw.githubusercontent.com/sergelogvinov/proxmox-csi-plugin/${ver}/docs/deploy/proxmox-csi-plugin-release.yml" "${ns}"
	storage_scc_binding "${ns}" proxmox-csi-plugin-node privileged
	storage_scc_binding "${ns}" proxmox-csi-plugin-controller nonroot-v2

	local url=${endpoint%/}
	url=${url%/api2/json}/api2/json
	local config
	config=$(jq -n --arg url "${url}" --argjson insecure "${insecure}" --arg id "${token%%=*}" \
		--arg secret "${token#*=}" --arg region "${region}" \
		'{clusters: [{url: $url, insecure: $insecure, token_id: $id, token_secret: $secret, region: $region}]}' | yq -P '.')
	# The secret goes straight to the API, not into the manifest queue on disk.
	if ! dry_run_note "would create secret ${ns}/proxmox-csi-plugin with the CSI token"; then
		storage_apply_queued
		oc create secret generic proxmox-csi-plugin -n "${ns}" --from-file=config.yaml=/dev/stdin \
			--dry-run=client -o yaml <<<"${config}" | oc apply -f - >/dev/null
	fi

	storage_emit <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
  labels:
    okd-pve/managed: "true"
provisioner: csi.proxmox.sinextra.dev
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  storage: ${pstorage}
  csi.storage.k8s.io/fstype: $(cfg '.storage.proxmox_csi.fstype')
  cache: $(cfg '.storage.proxmox_csi.cache')
  ssd: "$(cfg '.storage.proxmox_csi.ssd')"
EOF
	storage_apply_queued

	# Topology: region = Proxmox cluster, zone = Proxmox node of the VM. The
	# driver finds the VM by node name. Re-run after migrating VMs.
	local name host
	while IFS=$'\t' read -r name host; do
		if dry_run_note "would label ${name} topology.kubernetes.io/region=${region},zone=${host}"; then
			continue
		fi
		oc label node "${name}" "topology.kubernetes.io/region=${region}" "topology.kubernetes.io/zone=${host}" --overwrite >/dev/null ||
			log_warn "Could not label node ${name}"
	done < <(nodes_query '.[] | "\(.name)\t\(.host)"')
	if ! ((DRY_RUN)); then
		run_logged oc -n "${ns}" rollout status deployment/proxmox-csi-plugin-controller --timeout=300s ||
			die "${EXIT_ERROR}" "Proxmox CSI controller did not become ready." "oc -n ${ns} get pods; oc -n ${ns} logs deploy/proxmox-csi-plugin-controller"
		run_logged oc -n "${ns}" rollout status daemonset/proxmox-csi-plugin-node --timeout=300s ||
			die "${EXIT_ERROR}" "Proxmox CSI node plugin did not become ready." "oc -n ${ns} get pods"
	fi
}

# ---------------------------------------------------------------------------
# Ceph CSI (external Ceph cluster)
# ---------------------------------------------------------------------------

storage_ceph() {
	local sc=$1 ver ns=ceph-csi-rbd fsid pool user mons
	ver=$(cfg '.storage.ceph.version')
	fsid=$(cfg '.storage.ceph.cluster_id')
	pool=$(cfg '.storage.ceph.pool')
	user=$(cfg '.storage.ceph.user')
	mons=$(cfg_json '.storage.ceph.monitors')
	storage_load_secret_file "${CLUSTER_DIR}/ceph-csi.conf"
	local key=${CEPH_USER_KEY:-}
	[[ -n ${fsid} && -n ${pool} && -n ${user} && ${mons} != '[]' ]] ||
		die "${EXIT_CONFIG}" "storage.ceph needs cluster_id (fsid), monitors, pool and user." \
			"On a Proxmox host: 'ceph fsid', 'ceph mon dump', and create a pool + client (docs/storage.md)."
	[[ -n ${key} ]] || die "${EXIT_CONFIG}" "CEPH_USER_KEY is not set." \
		"Put CEPH_USER_KEY=<key of client.${user}> into ${CLUSTER_DIR}/ceph-csi.conf (mode 600) or the environment."
	redact_register "${key}"

	storage_ensure_namespace "${ns}"
	log_info "ceph-csi ${ver} (RBD) against cluster ${fsid}"
	local base="https://raw.githubusercontent.com/ceph/ceph-csi/${ver}/deploy/rbd/kubernetes" f
	for f in csidriver csi-provisioner-rbac csi-nodeplugin-rbac csi-rbdplugin-provisioner csi-rbdplugin; do
		storage_fetch_manifest "${base}/${f}.yaml" "${ns}"
	done
	storage_scc_binding "${ns}" rbd-csi-provisioner privileged
	storage_scc_binding "${ns}" rbd-csi-nodeplugin privileged
	storage_emit <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: ${ns}
data:
  config.json: |-
    $(jq -cn --arg id "${fsid}" --argjson m "${mons}" '[{clusterID: $id, monitors: $m}]')
EOF
	storage_emit <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-config
  namespace: ${ns}
data:
  ceph.conf: |
    [global]
    auth_cluster_required = cephx
    auth_service_required = cephx
    auth_client_required = cephx
  keyring: ""
EOF
	storage_emit <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-encryption-kms-config
  namespace: ${ns}
data:
  config.json: "{}"
EOF
	if ! dry_run_note "would create secret ${ns}/csi-rbd-secret for client.${user}"; then
		storage_apply_queued
		oc create secret generic csi-rbd-secret -n "${ns}" --from-literal=userID="${user}" \
			--from-file=userKey=/dev/stdin --dry-run=client -o yaml <<<"${key}" | oc apply -f - >/dev/null
	fi
	storage_emit <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
  labels:
    okd-pve/managed: "true"
provisioner: rbd.csi.ceph.com
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions: [discard]
parameters:
  clusterID: ${fsid}
  pool: ${pool}
  imageFeatures: layering
  csi.storage.k8s.io/fstype: $(cfg '.storage.ceph.fstype')
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ${ns}
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ${ns}
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ${ns}
EOF
	storage_apply_queued
	if ! ((DRY_RUN)); then
		run_logged oc -n "${ns}" rollout status deployment/csi-rbdplugin-provisioner --timeout=300s ||
			die "${EXIT_ERROR}" "ceph-csi provisioner did not become ready." "oc -n ${ns} get pods"
		run_logged oc -n "${ns}" rollout status daemonset/csi-rbdplugin --timeout=300s ||
			die "${EXIT_ERROR}" "ceph-csi node plugin did not become ready." "oc -n ${ns} get pods"
	fi
}

# ---------------------------------------------------------------------------
# Local Storage Operator (+ optional ODF)
# ---------------------------------------------------------------------------

# storage_lso <sc>: sets STORAGE_SC to the class to use afterwards (the ODF
# RBD class when ODF is enabled).
storage_lso() {
	local sc=$1 groups disks nodes mode fstype odf
	odf=$(jq -r '.storage.lso.odf' "${CONFIG_JSON}")
	mode=$(cfg '.storage.lso.volume_mode')
	fstype=$(cfg '.storage.lso.fstype')
	[[ ${odf} == true ]] && mode=Block
	groups=$(cfg_json '.storage.lso.node_groups')
	local sel
	sel=$(nodes_json | jq -c --argjson g "${groups}" '[.[] | select(.agent_role == "worker" and (.data_disks | length) > 0)
		| select(($g | length) == 0 or (.group as $x | $g | index($x)))]')
	[[ ${sel} != '[]' ]] || die "${EXIT_CONFIG}" "No worker nodes with data_disks for the Local Storage Operator." \
		"Add data_disks to a node group and list it in storage.lso.node_groups."
	nodes=$(jq -c '[.[].name]' <<<"${sel}")
	disks=$(jq -c '[.[].data_disks[].serial | "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_" + .]' <<<"${sel}")

	if ((DRY_RUN)); then
		dry_run_note "would install the Local Storage Operator ($(operator_coordinates local-storage || echo 'not in catalog'))"
	else
		install_operator_by_key local-storage || die "${EXIT_ERROR}" "Installing the Local Storage Operator failed."
	fi
	local lso_ns
	lso_ns=$(operator_coordinates local-storage | awk '{ print $3 }')
	lso_ns=${lso_ns:-openshift-local-storage}
	jq -n --arg ns "${lso_ns}" --arg sc "${sc}" --arg mode "${mode}" --arg fs "${fstype}" \
		--argjson nodes "${nodes}" --argjson disks "${disks}" --argjson tol "$(infra_tolerations_flow)" '{
		apiVersion: "local.storage.openshift.io/v1",
		kind: "LocalVolume",
		metadata: {name: "okd-pve-data-disks", namespace: $ns},
		spec: {
			nodeSelector: {nodeSelectorTerms: [{matchExpressions: [{key: "kubernetes.io/hostname", operator: "In", values: $nodes}]}]},
			tolerations: $tol,
			storageClassDevices: [{storageClassName: $sc, volumeMode: $mode, devicePaths: $disks}
				+ (if $mode == "Filesystem" then {fsType: $fs} else {} end)]
		}}' | yq -P '.' | storage_emit
	storage_apply_queued
	log_info "LocalVolume okd-pve-data-disks: $(jq length <<<"${disks}") disk(s) on $(jq length <<<"${nodes}") node(s), volumeMode ${mode}"

	if [[ ${odf} != true ]]; then
		STORAGE_SC=${sc}
		return
	fi

	local count=$(($(jq length <<<"${disks}") / 3))
	((count >= 1)) || die "${EXIT_CONFIG}" "ODF needs at least 3 data disks on 3 nodes." "Add data_disks to at least 3 worker nodes."
	if ((DRY_RUN)); then
		dry_run_note "would install ODF ($(operator_coordinates odf || echo 'not in catalog')) and create StorageCluster with ${count} device set(s) of 3"
		STORAGE_SC=ocs-storagecluster-ceph-rbd
		return
	fi
	local n
	for n in $(jq -r '.[]' <<<"${nodes}"); do
		oc label node "${n}" cluster.ocs.openshift.io/openshift-storage="" --overwrite >/dev/null
	done
	install_operator_by_key odf || die "${EXIT_ERROR}" "Installing ODF failed."
	jq -n --arg sc "${sc}" --argjson count "${count}" --argjson tol "$(infra_tolerations_flow)" '{
		apiVersion: "ocs.openshift.io/v1", kind: "StorageCluster",
		metadata: {name: "ocs-storagecluster", namespace: "openshift-storage"},
		spec: {
			monDataDirHostPath: "/var/lib/rook",
			placement: {all: {tolerations: $tol}},
			storageDeviceSets: [{
				name: "okd-pve-deviceset", count: $count, replica: 3, portable: false,
				dataPVCTemplate: {spec: {accessModes: ["ReadWriteOnce"], volumeMode: "Block",
					storageClassName: $sc, resources: {requests: {storage: "1"}}}}
			}]
		}}' | yq -P '.' | storage_emit
	storage_apply_queued
	log_info "Waiting for the ODF StorageCluster (this takes 10-20 minutes)"
	oc_wait 2400 "StorageCluster ocs-storagecluster to be Ready" \
		bash -c '[[ $(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath="{.status.phase}") == Ready ]]' ||
		die "${EXIT_ERROR}" "ODF StorageCluster did not become Ready." "oc -n openshift-storage get pods; oc describe storagecluster -n openshift-storage"
	STORAGE_SC=ocs-storagecluster-ceph-rbd
}

# ---------------------------------------------------------------------------
# NFS
# ---------------------------------------------------------------------------

storage_nfs() {
	local sc=$1 server path ns=okd-pve-nfs-provisioner provisioner=okd-pve/nfs-subdir
	server=$(cfg '.storage.nfs.server')
	path=$(cfg '.storage.nfs.path')
	[[ -n ${server} && -n ${path} ]] || die "${EXIT_CONFIG}" "storage.nfs needs server and path." \
		"Set storage.nfs.server and storage.nfs.path to an export writable by the nodes."
	log_info "nfs-subdir-external-provisioner on ${server}:${path}"
	TPL=([NAMESPACE]=${ns} [IMAGE]=$(cfg '.storage.nfs.image') [PROVISIONER]=${provisioner}
	[SERVER]=${server} [PATH]=${path} [TOLERATIONS]=$(infra_tolerations_flow))
	render_template "${OKD_PVE_ROOT}/templates/storage/nfs-subdir-provisioner.yaml.tpl" | storage_emit
	storage_emit <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
  labels:
    okd-pve/managed: "true"
provisioner: ${provisioner}
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  archiveOnDelete: "$(cfg '.storage.nfs.archive_on_delete')"
EOF
	storage_apply_queued
	if ! ((DRY_RUN)); then
		run_logged oc -n "${ns}" rollout status deployment/nfs-subdir-provisioner --timeout=300s ||
			die "${EXIT_ERROR}" "NFS provisioner did not become ready." \
				"oc -n ${ns} describe pod; check that the nodes may mount ${server}:${path}."
	fi
}
