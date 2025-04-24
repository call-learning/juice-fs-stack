#!/bin/bash

set -euo pipefail

NAMESPACE="juicefs-system"
RELEASE="juicefs-test"
PVC_NAME="juicefs-pvc"
CHART_DIR="$(dirname "$0")/.."
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
SCRIPT_DIR=$(realpath "$(dirname "$0")")
if [ "$NO_PREPARE" -eq 0 ]; then
  echo "Preparing JuiceFS cluster in namespace $NAMESPACE with release $RELEASE..."
  "$SCRIPT_DIR/prepare-jfs-cluster.sh" "$NAMESPACE" "$RELEASE"
else
  echo "Skipping JuiceFS cluster preparation."
fi


function info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}
"$SCRIPT_DIR/create-pvc.sh" "$NAMESPACE" "$PVC_NAME"

info "Upgrading helm script"
helm upgrade "$RELEASE" "$CHART_DIR" \
  -n "$NAMESPACE" \
  --wait

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

info "Waiting for writer to complete..."
kubectl wait --for=condition=complete job/writer -n "$NAMESPACE" --timeout=360s
info "Waiting for reader to complete..."
kubectl wait --for=condition=complete job/reader -n "$NAMESPACE" --timeout=360s

info "Checking reader logs:"
kubectl logs job/reader -n "$NAMESPACE"

echo "🎉 JuiceFS test succeeded: file was written and read successfully!"

info "✅ JuiceFS S3 volume test completed."


if [ "$NO_PREPARE" -eq 0 ]; then
  echo "Preparing JuiceFS cluster in namespace $NAMESPACE with release $RELEASE..."
  "$SCRIPT_DIR/prepare-jfs-cluster.sh" "$NAMESPACE" "$RELEASE"
else
  echo "Skipping JuiceFS cluster deletion."
fi
