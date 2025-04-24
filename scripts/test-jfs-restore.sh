#!/bin/bash

set -euo pipefail

NAMESPACE="juicefs-system"
RELEASE="juicefs-test"
PVC_NAME="juicefs-pvc"
TEST_FILE="/mnt/juicefs/test-file.txt"
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

"$SCRIPT_DIR/create-pvc.sh" "$NAMESPACE" "$RELEASE"

info "Upgrading helm script"
RCLONE_CONFIG="$(kubectl get secret juicefs-test-rclone-secret -n "$NAMESPACE" -o jsonpath="{.data.rclone\.conf}" | base64 --decode)"

helm upgrade "$RELEASE" "$CHART_DIR" \
  -n "$NAMESPACE" \
  --set "juicefs.backup.s3.rcloneConfigContent=${RCLONE_CONFIG}" \
  --wait

# Step 1: Create a file in JuiceFS
info "Creating a test file in JuiceFS..."
kubectl delete job juicefs-create-file -n "$NAMESPACE" || true
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: juicefs-create-file
spec:
  template:
    spec:
      containers:
        - name: writer
          image: busybox
          command: ["/bin/sh", "-c"]
          args: ["echo 'test data' > $TEST_FILE"]
          volumeMounts:
            - mountPath: "/mnt/juicefs"
              name: juicefs-vol
      volumes:
        - name: juicefs-vol
          persistentVolumeClaim:
            claimName: $PVC_NAME
      restartPolicy: Never
EOF

kubectl wait --for=condition=complete job/juicefs-create-file -n "$NAMESPACE" --timeout=300s
kubectl delete job juicefs-create-file -n "$NAMESPACE"

# Step 2: Trigger a backup
info "Waiting for the backup CronJob to run..."
info "Creating a backup job from the CronJob..."
kubectl delete job backup-job -n "$NAMESPACE" || true
kubectl create job --from=cronjob/juicefs-test-redis-backup backup-job -n "$NAMESPACE"
kubectl wait --for=condition=complete job/backup-job -n "$NAMESPACE" --timeout=300s

# Step 3: Simulate Redis failure
info "Simulating Redis failure by deleting the Redis service..."
kubectl delete svc redis-jfs -n "$NAMESPACE"

# Step 4: Restore Redis using the Helm chart
info "Restoring Redis using the Helm chart..."
helm upgrade --install "$RELEASE" ./juicefs-stack \
  --namespace "$NAMESPACE" \
  --set juicefs.restore.enabled=true \
  --set juicefs.restore.s3Key="path/to/backup/dump.rdb"

# Step 5: Verify the restored data
info "Verifying the restored data..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: juicefs-verify-restore
spec:
  template:
    spec:
      containers:
        - name: reader
          image: busybox
          command: ["/bin/sh", "-c"]
          args: ["cat $TEST_FILE"]
          volumeMounts:
            - mountPath: "/mnt/juicefs"
              name: juicefs-vol
      volumes:
        - name: juicefs-vol
          persistentVolumeClaim:
            claimName: $PVC_NAME
      restartPolicy: Never
EOF

kubectl wait --for=condition=complete job/juicefs-verify-restore -n "$NAMESPACE"
kubectl logs juicefs-verify-restore -n "$NAMESPACE"
kubectl delete job juicefs-verify-restore -n "$NAMESPACE"

info "✅ End-to-end test completed successfully."

if [ "$NO_PREPARE" -eq 0 ]; then
  echo "Preparing JuiceFS cluster in namespace $NAMESPACE with release $RELEASE..."
  "$SCRIPT_DIR/prepare-jfs-cluster.sh" "$NAMESPACE" "$RELEASE"
else
  echo "Skipping JuiceFS cluster deletion."
fi
