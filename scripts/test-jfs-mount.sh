#!/bin/bash

set -euo pipefail

NAMESPACE="juicefs-system"
RELEASE="juicefs-test"
NO_PREPARE=0

while getopts "n" opt; do
  case ${opt} in
    n )
      NO_PREPARE=1
      ;;
    \? )
      echo "Usage: $0 [-n] [NAMESPACE] [RELEASE]"
      exit 1
      ;;
  esac
done

shift $((OPTIND -1))

if [ "$NO_PREPARE" -eq 0 ]; then
  echo "Preparing JuiceFS cluster in namespace $NAMESPACE with release $RELEASE..."
  SCRIPT_DIR=$(realpath "$(dirname "$0")")
  "$SCRIPT_DIR/prepare-jfs-cluster.sh" "$NAMESPACE" "$RELEASE"
else
  echo "Skipping JuiceFS cluster preparation."
fi

function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

info "Creating PVC and SC..."

PVC_NAME="juicefs-pvc"
echo "Attempting normal deletion of PVC $PVC_NAME in $NAMESPACE..."
if kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "Attempting normal deletion of PVC $PVC_NAME in $NAMESPACE..."
  if ! kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" --timeout=10s; then
    echo "Normal deletion failed. Forcing finalizer removal..."

    kubectl patch pvc "$PVC_NAME" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge

    # Try to delete again
    echo "Retrying deletion..."
    kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" || echo "Failed to delete PVC"
  else
    echo "PVC deleted successfully."
  fi
else
  echo "PVC $PVC_NAME does not exist in namespace $NAMESPACE. Skipping deletion."
fi


kubectl delete sc juicefs-sc -n "$NAMESPACE" || true
kubectl delete pod juicefs-test-pod -n "$NAMESPACE" || true

# Retrieve existing info for S3
S3_ACCESS_KEY=$(kubectl get secret juicefs-s3-secret -n "$NAMESPACE" -o jsonpath="{.data.JFS_ACCESS_KEY}" | base64 --decode)
S3_SECRET_KEY=$(kubectl get secret juicefs-s3-secret -n "$NAMESPACE" -o jsonpath="{.data.JFS_SECRET_KEY}" | base64 --decode)
S3_BUCKET=$(kubectl get secret juicefs-s3-secret -n "$NAMESPACE" -o jsonpath="{.data.JFS_BUCKET}" | base64 --decode)

# Retrieve metat URL
METAURL=$(kubectl get secret juicefs-csi-config -n "$NAMESPACE" -o jsonpath="{.data.metaurl}" | base64 --decode)

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: juicefs-s3-secret
type: Opaque
stringData:
  metaurl: "$METAURL"
  storage: s3
  name: juicefs-k8s-drive
  bucket: "$S3_BUCKET"
  access-key: "$S3_ACCESS_KEY"
  secret-key: "$S3_SECRET_KEY"
EOF

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: juicefs-sc
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: juicefs-s3-secret
  csi.storage.k8s.io/provisioner-secret-namespace: $NAMESPACE
  csi.storage.k8s.io/node-publish-secret-name: juicefs-s3-secret
  csi.storage.k8s.io/node-publish-secret-namespace: $NAMESPACE
reclaimPolicy: Retain
volumeBindingMode: Immediate
EOF


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
      storage: 50Mi
EOF

info "Creating test pod..."

info "Creating writer job..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: writer
spec:
  template:
    spec:
      containers:
      - name: writer
        image: busybox
        command: ["sh", "-c", "echo 'hello juicefs' > /mnt/jfs/test.txt"]
        volumeMounts:
        - name: jfs
          mountPath: /mnt/jfs
      restartPolicy: Never
      volumes:
      - name: jfs
        persistentVolumeClaim:
          claimName: $PVC_NAME
EOF

info "Waiting for writer to complete..."
kubectl wait --for=condition=complete job/writer -n "$NAMESPACE" --timeout=60s

info "Creating reader job..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: reader
spec:
  template:
    spec:
      containers:
      - name: reader
        image: busybox
        command: ["sh", "-c", "until [ -f /mnt/jfs/test.txt ]; do echo waiting...; sleep 2; done; grep 'hello juicefs' /mnt/jfs/test.txt"]
        volumeMounts:
        - name: jfs
          mountPath: /mnt/jfs
      restartPolicy: Never
      volumes:
      - name: jfs
        persistentVolumeClaim:
          claimName: $PVC_NAME
EOF

info "Waiting for reader to complete..."
kubectl wait --for=condition=complete job/reader -n "$NAMESPACE" --timeout=60s

info "Checking reader logs:"
kubectl logs job/reader -n "$NAMESPACE"

echo "🎉 JuiceFS test succeeded: file was written and read successfully!"

info "✅ JuiceFS S3 volume test completed."


if [ "$NO_PREPARE" -eq 0 ]; then
  echo "Preparing JuiceFS cluster in namespace $NAMESPACE with release $RELEASE..."
  ./destroy-jfs-cluster.sh "$NAMESPACE" "$RELEASE"
else
  echo "Skipping JuiceFS cluster deletion."
fi
