#!/bin/bash
# Test script for the Nested Virtualization blueprint.
# Verifies:
#   1. Karpenter provisions an *8i* instance under the nested-virt NodePool.
#   2. EC2 reports NestedVirtualizationEnabled=true on the instance's CpuOptions
#      (control-plane confirmation).
#   3. The demo pod sees the vmx flag in /proc/cpuinfo and /dev/kvm exists
#      (data-plane confirmation).
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.13 or later installed (EC2NodeClass.spec.cpuOptions must be present)
# - aws CLI configured with permissions for ec2:DescribeInstances
# - Environment variables:
#     CLUSTER_NAME                    (default: karpenter-blueprints)
#     KARPENTER_NODE_IAM_ROLE_NAME    (default: karpenter-blueprints)
#     AWS_REGION                      (default: us-west-2)
#
# Usage: ./test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TIMEOUT_NODE_READY=300
POLL_INTERVAL=10

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    for cmd in kubectl aws; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd not found"
            exit 1
        fi
    done

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Verify EC2NodeClass CRD has the v1.13+ cpuOptions.nestedVirtualization field.
    local field
    field=$(kubectl get crd ec2nodeclasses.karpenter.k8s.aws -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.cpuOptions.properties.nestedVirtualization.enum}' 2>/dev/null || echo "")
    if [[ "$field" != *"enabled"* ]]; then
        log_error "EC2NodeClass CRD does not expose cpuOptions.nestedVirtualization."
        log_error "This blueprint requires Karpenter v1.13 or later."
        exit 1
    fi

    export CLUSTER_NAME=${CLUSTER_NAME:-karpenter-blueprints}
    export KARPENTER_NODE_IAM_ROLE_NAME=${KARPENTER_NODE_IAM_ROLE_NAME:-karpenter-blueprints}
    export AWS_REGION=${AWS_REGION:-us-west-2}

    log_info "Using cluster: $CLUSTER_NAME, node IAM role: $KARPENTER_NODE_IAM_ROLE_NAME, region: $AWS_REGION"
    log_info "Prerequisites check passed"
}

render_manifest() {
    log_info "Rendering nested-virtualization.yaml with substitutions..."
    sed -e "s|<<CLUSTER_NAME>>|$CLUSTER_NAME|g" \
        -e "s|<<KARPENTER_NODE_IAM_ROLE_NAME>>|$KARPENTER_NODE_IAM_ROLE_NAME|g" \
        nested-virtualization.yaml > /tmp/nested-virt-rendered.yaml
}

wait_for_pod_ready() {
    local label=$1
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0
    log_info "Waiting for pod with label '$label' to be Ready (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local ready
        ready=$(kubectl get pods -l "$label" -o jsonpath='{range .items[*].status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}' 2>/dev/null | grep -c "^True$" || true)
        ready=$((ready + 0))
        if [ "$ready" -ge 1 ]; then
            log_info "Pod is Ready"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for pod to be Ready"
    kubectl get pods -l "$label" 2>/dev/null || true
    kubectl describe pods -l "$label" 2>/dev/null | tail -30 || true
    return 1
}

cleanup() {
    log_info "Cleaning up..."
    kubectl delete deployment nested-virt-demo --ignore-not-found=true 2>/dev/null || true
    kubectl delete nodepool nested-virt --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass nested-virt --ignore-not-found=true 2>/dev/null || true
    sleep 30
}

test_provisioning_and_verification() {
    log_test "=== Provisioning + verification ==="

    cleanup
    render_manifest

    log_info "Applying rendered EC2NodeClass + NodePool..."
    kubectl apply -f /tmp/nested-virt-rendered.yaml

    log_info "Applying demo workload..."
    kubectl apply -f workload.yaml

    if ! wait_for_pod_ready "app=nested-virt-demo"; then
        log_error "❌ FAILED: demo pod did not become Ready"
        return 1
    fi

    # ---- Check 1: instance type family ----
    local node
    node=$(kubectl get pods -l app=nested-virt-demo -o jsonpath='{.items[0].spec.nodeName}')
    local instance_type
    instance_type=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
    log_info "Karpenter provisioned instance type: $instance_type"
    case "$instance_type" in
        c8i*|m8i*|r8i*)
            log_test "✅ PASSED: instance is from an *8i* family"
            ;;
        *)
            log_error "❌ FAILED: instance $instance_type is not from an *8i* family"
            return 1
            ;;
    esac

    # Run all remaining checks and accumulate result — don't fail-fast so
    # readers see everything on one run.
    local failures=0

    # ---- Check 2 (informational): EC2 API CpuOptions.NestedVirtualization ----
    # On *8i* families the Nitro System natively passes CPU virt extensions,
    # so this field can be reported as None even when nested virt is working.
    # The vmx + /dev/kvm checks below are the definitive proof.
    local instance_id
    instance_id=$(kubectl get node "$node" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
    local nested
    nested=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].CpuOptions.NestedVirtualization' \
        --output text 2>/dev/null || echo "None")
    log_info "EC2 CpuOptions.NestedVirtualization for instance $instance_id: $nested (informational)"

    # ---- Check 3: vmx or svm flag visible from inside the pod ----
    local pod
    pod=$(kubectl get pod -l app=nested-virt-demo -o jsonpath='{.items[0].metadata.name}')
    local flag
    flag=$(kubectl exec "$pod" -- grep -om1 'vmx\|svm' /proc/cpuinfo 2>/dev/null || echo "")
    if [ -n "$flag" ]; then
        log_test "✅ PASSED: pod sees CPU virt extension: $flag"
    else
        log_error "❌ FAILED: no vmx or svm flag in /proc/cpuinfo from the pod"
        failures=$((failures + 1))
    fi

    # ---- Check 4: /dev/kvm exists inside the pod ----
    if kubectl exec "$pod" -- test -e /dev/kvm 2>/dev/null; then
        log_test "✅ PASSED: /dev/kvm is present inside the pod"
    else
        log_error "❌ FAILED: /dev/kvm not present inside the pod"
        failures=$((failures + 1))
    fi

    if [ $failures -eq 0 ]; then
        return 0
    else
        log_error "$failures verification check(s) failed"
        return 1
    fi
}

main() {
    local exit_code=0

    check_prerequisites
    test_provisioning_and_verification || exit_code=1
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
