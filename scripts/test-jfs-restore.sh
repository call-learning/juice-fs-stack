#!/bin/bash

set -euo pipefail

NAMESPACE="juicefs-system"
RELEASE="juicefs-test"
PVC_NAME="juicefs-pvc"

function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

info "Simulating Redis failure by deleting the master pod..."
kubectl delete pod redis-jfs-master-0 -n "$NAMESPACE"

info "Running Redis restore job from S3..."
kubectl apply -f charts/juicefs-core/templates/juicefs-restore-job.yaml

info "Waiting for Redis restore job to complete..."
kubectl wait --for=condition=complete job/${RELEASE}-redis-restore -n "$NAMESPACE" --timeout=60s

info "Restarting Redis master pod to load restored data..."
kubectl delete pod redis-jfs-master-0 -n "$NAMESPACE"

info "Waiting for Redis master pod to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=master -n "$NAMESPACE" --timeout=60s

info "Creating test pod to verify JuiceFS after Redis restore..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: juicefs-sc
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: juicefs-post-restore-test
spec:
  containers:
    - name: test
      image: busybox
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "[TEST] Listing contents after restore:" && \
          ls -l /mnt/juicefs && \
          echo "[TEST] Attempting to read restored.txt:" && \
          cat /mnt/juicefs/restored.txt || echo "[ERROR] restored.txt not found" && \
          echo "[TEST] Writing post-restore check file..." && \
          echo "restored write check" > /mnt/juicefs/test-after-restore.txt && \
          cat /mnt/juicefs/test-after-restore.txt
      volumeMounts:
        - mountPath: "/mnt/juicefs"
          name: juicefs-vol
  volumes:
    - name: juicefs-vol
      persistentVolumeClaim:
        claimName: $PVC_NAME
  restartPolicy: Never
EOF

info "Waiting for test pod to complete..."
kubectl wait --for=condition=Succeeded pod/juicefs-post-restore-test -n "$NAMESPACE" --timeout=60s

info "Fetching logs from post-restore test pod..."
kubectl logs juicefs-post-restore-test -n "$NAMESPACE"

info "✅ JuiceFS end-to-end restore validation completed."
