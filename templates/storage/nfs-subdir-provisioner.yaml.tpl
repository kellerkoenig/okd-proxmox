# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# nfs-subdir-external-provisioner: one subdirectory per PVC on an existing
# NFS export.
apiVersion: v1
kind: Namespace
metadata:
  name: {{NAMESPACE}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-subdir-provisioner
  namespace: {{NAMESPACE}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: okd-pve-nfs-subdir-provisioner
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [persistentvolumes]
    verbs: [get, list, watch, create, delete]
  - apiGroups: [""]
    resources: [persistentvolumeclaims]
    verbs: [get, list, watch, update]
  - apiGroups: [storage.k8s.io]
    resources: [storageclasses]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [events]
    verbs: [create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: okd-pve-nfs-subdir-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-subdir-provisioner
    namespace: {{NAMESPACE}}
roleRef:
  kind: ClusterRole
  name: okd-pve-nfs-subdir-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: leader-locking-nfs-subdir-provisioner
  namespace: {{NAMESPACE}}
rules:
  - apiGroups: [""]
    resources: [endpoints]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [coordination.k8s.io]
    resources: [leases]
    verbs: [get, list, watch, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: leader-locking-nfs-subdir-provisioner
  namespace: {{NAMESPACE}}
subjects:
  - kind: ServiceAccount
    name: nfs-subdir-provisioner
    namespace: {{NAMESPACE}}
roleRef:
  kind: Role
  name: leader-locking-nfs-subdir-provisioner
  apiGroup: rbac.authorization.k8s.io
---
# The pod mounts the NFS export directly, which the restricted SCCs do not
# allow; hostmount-anyuid permits nfs volumes.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nfs-subdir-provisioner-scc
  namespace: {{NAMESPACE}}
subjects:
  - kind: ServiceAccount
    name: nfs-subdir-provisioner
    namespace: {{NAMESPACE}}
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:hostmount-anyuid
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-subdir-provisioner
  namespace: {{NAMESPACE}}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-subdir-provisioner
  template:
    metadata:
      labels:
        app: nfs-subdir-provisioner
    spec:
      serviceAccountName: nfs-subdir-provisioner
      tolerations: {{TOLERATIONS}}
      containers:
        - name: provisioner
          image: {{IMAGE}}
          env:
            - name: PROVISIONER_NAME
              value: {{PROVISIONER}}
            - name: NFS_SERVER
              value: "{{SERVER}}"
            - name: NFS_PATH
              value: "{{PATH}}"
          volumeMounts:
            - name: nfs-root
              mountPath: /persistentvolumes
      volumes:
        - name: nfs-root
          nfs:
            server: "{{SERVER}}"
            path: "{{PATH}}"
