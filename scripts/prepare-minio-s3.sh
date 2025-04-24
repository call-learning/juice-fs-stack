#!/bin/bash

set -euo pipefail

NAMESPACE="${1:-juicefs-system}"
CHART_DIR="$(dirname "$0")/.."
MINIO_USER="minio"
MINIO_PASS="minio123"
BUCKET="test-bucket"
BACKUP_BUCKET="juicefs-metadata"

function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

function wait_for_ready() {
  kubectl rollout status deployment/$1 -n $2 --timeout=60s
}

info "Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" || true

info "Deploying MinIO in $NAMESPACE"
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio
          args: ["server", "/data"]
          env:
            - name: MINIO_ROOT_USER
              value: $MINIO_USER
            - name: MINIO_ROOT_PASSWORD
              value: $MINIO_PASS
          ports:
            - containerPort: 9000
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
EOF

info "Waiting for MinIO to be ready..."
wait_for_ready minio "$NAMESPACE"

info "Creating MinIO buckets via job"
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: create-buckets
spec:
  template:
    spec:
      containers:
        - name: mc
          image: minio/mc
          command: ["/bin/sh", "-c"]
          args:
            - |
              mc alias set local http://minio:9000 $MINIO_USER $MINIO_PASS && \
              mc mb local/$BUCKET && \
              mc mb local/$BACKUP_BUCKET
      restartPolicy: OnFailure
EOF
kubectl wait --for=condition=complete job/create-buckets -n "$NAMESPACE"

info "Creating JuiceFS S3 credentials secret"
kubectl create secret generic juicefs-s3-secret \
  -n "$NAMESPACE" \
  --from-literal=JFS_ACCESS_KEY="$MINIO_USER" \
  --from-literal=JFS_SECRET_KEY="$MINIO_PASS" \
  --from-literal=JFS_BUCKET="s3://$BUCKET" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Creating S3 rclone config (for backup)"
# Define your rclone.conf content inline
RCLONE_CONFIG=$(cat <<EOF
[s3backup]
type = s3
provider = Minio
env_auth = false
access_key_id = ${MINIO_USER:-admin}
secret_access_key = ${MINIO_PASS:-admin123}
endpoint = http://minio.default.svc.cluster.local:9000
region = us-east-1
acl = private
EOF
)

# Create a rclone-config secret
kubectl create secret generic redis-rclone-config \
  -n "$NAMESPACE" \
  --from-literal=rclone.conf="$RCLONE_CONFIG" \
  --dry-run=client -o yaml | kubectl apply -f -
