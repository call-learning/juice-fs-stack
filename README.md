# JuiceFS Stack Helm Chart - Test Setup Guide

This guide explains how to run **unit** and **integration tests** for the JuiceFS Helm chart.

---

## 🔧 Local Setup Instructions

### 1. Clone the Repository
```bash
git clone https://github.com/your-org/juicefs-stack.git
cd juicefs-stack
```

### 2. Install Required Tools
Make sure you have the following installed:
- [Helm 3](https://helm.sh/docs/intro/install/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kind](https://kind.sigs.k8s.io/)

Install the Helm unit test plugin:
```bash
helm plugin install https://github.com/helm-unittest/helm-unittest
```

### 3. Run All Tests Locally
We provide a script to automate the full testing process:
```bash
chmod +x scripts/run-integration-tests.sh
./scripts/run-integration-tests.sh
```

This script will:
- Run `helm unittest` on your chart
- Create a local Kubernetes cluster using `kind`
- Install the chart
- Wait for the `juicefs-format` job to complete
- Mount JuiceFS in a test pod and write to it
- Clean up all resources

---

## 🚀 CI/CD Testing with GitHub Actions

This repository includes a GitHub Actions workflow that runs both unit and integration tests on every push and PR:

### File: `.github/workflows/ci-test-workflow.yaml`
```yaml
name: Helm Integration and Unit Tests

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - "*"

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v3

      - name: Set up Helm
        uses: azure/setup-helm@v3
        with:
          version: v3.12.0

      - name: Install helm-unittest plugin
        run: helm plugin install https://github.com/helm-unittest/helm-unittest

      - name: Set up kind cluster
        uses: helm/kind-action@v1.5.0

      - name: Set up kubectl
        uses: azure/setup-kubectl@v3
        with:
          version: v1.27.1

      - name: Run unit and integration tests
        run: |
          chmod +x scripts/run-integration-tests.sh
          scripts/run-integration-tests.sh
```

---

## ✅ Summary
| Task | How to Run |
|------|------------|
| Run all tests locally | `./scripts/run-integration-tests.sh` |
| Run in CI | Trigger GitHub Actions via push or PR |
| Unit test templates | `helm unittest .` inside the chart folder |

Need help extending these tests for new components? Let us know!
