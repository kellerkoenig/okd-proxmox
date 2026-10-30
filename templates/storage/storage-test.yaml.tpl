# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The okd-proxmox Authors
#
# Throw-away PVC and pod to prove that a StorageClass provisions, attaches
# and mounts a writable volume. Deleted again by okd-pve.
apiVersion: v1
kind: Namespace
metadata:
  name: {{NAMESPACE}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: okd-pve-test
  namespace: {{NAMESPACE}}
spec:
  storageClassName: {{STORAGE_CLASS}}
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: okd-pve-test
  namespace: {{NAMESPACE}}
spec:
  restartPolicy: Never
  tolerations: {{TOLERATIONS}}
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: {{IMAGE}}
      command: [/bin/sh, -c, "echo okd-pve > /data/probe && grep -q okd-pve /data/probe && echo OK"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: okd-pve-test
