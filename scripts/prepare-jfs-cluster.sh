#!/bin/bash

set -euo pipefail

NAMESPACE="${1:-juicefs-system}"
RELEASE="${2:-juicefs-test}"
CHART_DIR="$(dirname "$0")/.."
MINIO_USER="minio"
MINIO_PASS="minio123"
BUCKET="test-bucket"

function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

function wait_for_ready() {
  kubectl rollout status deployment/$1 -n $2 --timeout=60s
}

info "Deleting any existing kind cluster..."
kind delete cluster --name "$RELEASE"

info "Creating kind cluster with 1 control-plane and 2 workers..."
kind create cluster --name "$RELEASE" --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

info "Adding JuiceFS Helm repository..."
helm repo add juicefs https://juicedata.github.io/charts/

info "Updating Helm chart dependencies..."
helm dependency update "$CHART_DIR"

if [ ! -d "$CHART_DIR/charts" ] || [ -z "$(ls -A "$CHART_DIR/charts")" ]; then
  echo "[ERROR] Dependency update failed: 'charts/' folder is missing or empty."
  exit 1
fi

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

info "Creating MinIO bucket via job"
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: create-bucket
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
              mc mb local/$BUCKET
      restartPolicy: OnFailure
EOF
kubectl wait --for=condition=complete job/create-bucket -n "$NAMESPACE"

info "Creating JuiceFS S3 credentials secret"
kubectl create secret generic juicefs-s3-secret \
  -n "$NAMESPACE" \
  --from-literal=JFS_ACCESS_KEY="$MINIO_USER" \
  --from-literal=JFS_SECRET_KEY="$MINIO_PASS" \
  --from-literal=JFS_BUCKET="s3://$BUCKET" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Deploying Helm chart from $CHART_DIR..."

helm install "$RELEASE" "$CHART_DIR" \
  -n "$NAMESPACE" \
  --create-namespace \
  --replace \
  --wait

info "Creating standalone juicefs-format job..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: juicefs-manual-format
spec:
  template:
    spec:
      containers:
        - name: format
          image: juicedata/mount:ce-v1.2.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              export AWS_ACCESS_KEY_ID=\$JFS_ACCESS_KEY
              export AWS_SECRET_ACCESS_KEY=\$JFS_SECRET_KEY
              juicefs format --bucket=\$JFS_BUCKET $(kubectl get secret juicefs-csi-config -n $NAMESPACE -o jsonpath='{.data.metaurl}' | base64 -d) juicefs-sc
          envFrom:
            - secretRef:
                name: juicefs-s3-secret
      restartPolicy: Never
EOF

info "Waiting for manual juicefs-format job to complete..."
kubectl wait --for=condition=complete job/juicefs-manual-format -n "$NAMESPACE" --timeout=90s

