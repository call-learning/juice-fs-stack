#!/bin/bash

set -euo pipefail
NAMESPACE="${1:-juicefs-system}"
CHART="bitnami/redis"
CHART_VERSION="18.1.3"

function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

info "Creating namespace '$NAMESPACE' if it doesn't exist..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

info "Adding Bitnami Helm repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami

info "Create PVC for the redis master..."
# Now create the pvc for redis-data-redis-master-0 as a local pvc
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-data-redis-master-0-pv
spec:
  capacity:
    storage: 50Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/data/redis-data-redis-master-0
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data-redis-master-0
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  resources:
    requests:
      storage: 50Mi
  volumeName: redis-data-redis-master-0-pv
EOF


info "Installing Redis with backup sidecar..."
helm upgrade --install "redis-juicefs" "$CHART" \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values - <<EOF
enabled: true
architecture: replication
auth:
  enabled: true
  password: "CHANGEME"
fullnameOverride: redis-jfs
replica:
  replicaCount: 1
master:
  persistence:
    enabled: true
    existingClaim: redis-data-redis-jfs-master-0
  configmap: |-
    save 60 1000
    appendonly yes
    appendfsync everysec
  sidecars:
    - name: redis-backup
      image: rclone/rclone:latest
      args:
        - sync
        - /data
        - remote:juicefs-metadata/backups
      volumeMounts:
        - name: redis-data
          mountPath: /data
        - name: rclone-config
          mountPath: /config
  extraVolumes:
    - name: rclone-config
      secret:
        secretName: redis-rclone-config
sentinel:
  enabled: true
  masterSet: jfs-master
  quorum: 2
  usePasswordFile: true
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
EOF
