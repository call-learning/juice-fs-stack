#!/bin/bash

set -e

NAMESPACE="${1:-juicefs-system}"
RELEASE="${2:-juicefs-test}"

echo "Destroying JuiceFS resources in namespace $NAMESPACE..."

kind delete cluster --name "$RELEASE"

echo "JuiceFS cluster teardown complete."
