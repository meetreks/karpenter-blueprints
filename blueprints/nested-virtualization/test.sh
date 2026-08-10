#!/bin/bash
# Test script for the Nested Virtualization blueprint.
#
# Verifies three things end-to-end:
#
#   Test 1 (Karpenter plumbing): Karpenter provisions a nested-virt-capable
#     NodeClaim from the nested-virt NodePool, EC2 reports CpuOptions on the
#     launched instance, and the demo pod sees the vmx flag + /dev/kvm.
#
#   Test 2 (Kata MicroVM): the kata-verify pod runs via RuntimeClass
#     kata-qemu-runtime-rs and reports a guest kernel version that differs
#     from the host node's kernel, proof that Kata is actively wrapping the
#     pod in a MicroVM, not just installed.
#
#   Test 3 (Agent sandbox demo): the sandbox Deployment comes up on Kata,
#     accepts POST /exec, and the kernel reported in its JSON response also
#     differs from the host kernel, proof that arbitrary user-supplied code
#     lands inside the MicroVM boundary.
#
# All assertions are scoped to this blueprint's own resources (label
# `blueprint=nested-virtualization`, its own NodeClaims, its own workloads)
# so the script can't accidentally pass on unrelated cluster activity.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.13 or later (EC2NodeClass.spec.cpuOptions must be present)
# - Kata Containers installed via the upstream helm chart (see README step 2).
#   The script checks that RuntimeClass kata-qemu-runtime-rs exists and bails
#   out with instructions if it does not.
# - aws CLI configured with ec2:DescribeInstances permissions
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

TIMEOUT_NODE_READY=420
TIMEOUT_POD_READY=300
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

    # Karpenter v1.13+ exposes cpuOptions.nestedVirtualization on EC2NodeClass.
    local field
    field=$(kubectl get crd ec2nodeclasses.karpenter.k8s.aws -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.cpuOptions.properties.nestedVirtualization.enum}' 2>/dev/null || echo "")
    if [[ "$field" != *"enabled"* ]]; then
        log_error "EC2NodeClass CRD does not expose cpuOptions.nestedVirtualization."
        log_error "This blueprint requires Karpenter v1.13 or later."
        exit 1
    fi

    # Kata's kata-qemu-runtime-rs RuntimeClass must be registered on the
    # cluster before Test 2 and Test 3 can run. If it isn't, refuse rather
    # than reporting a misleading failure inside the kata-verify pod.
    if ! kubectl get runtimeclass kata-qemu-runtime-rs &> /dev/null; then
        log_error "RuntimeClass 'kata-qemu-runtime-rs' not found on the cluster."
        log_error "Install Kata Containers first. See README step 2 for the full helm"
        log_error "install command (it scopes the DaemonSet to this blueprint's nodes)."
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
    local timeout=${2:-$TIMEOUT_POD_READY}
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

wait_for_pod_phase() {
    # Wait until a pod (by name) reaches one of the given phases (space-separated).
    local name=$1
    local phases=$2
    local timeout=${3:-$TIMEOUT_POD_READY}
    local elapsed=0
    log_info "Waiting for pod '$name' to reach phase in [$phases] (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local phase
        phase=$(kubectl get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        for p in $phases; do
            if [ "$phase" = "$p" ]; then
                log_info "Pod '$name' is $phase"
                return 0
            fi
        done
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for pod '$name' to reach [$phases]"
    kubectl describe pod "$name" 2>/dev/null | tail -30 || true
    return 1
}

cleanup() {
    log_info "Cleaning up blueprint resources..."
    # Deliberately does NOT uninstall the kata-deploy Helm release: Kata is a
    # prerequisite this script checks for but doesn't own (see README Cleanup
    # for the helm uninstall step).
    kubectl delete -f sandbox.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f sandbox-workload.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete nodepool nested-virt --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass nested-virt --ignore-not-found=true 2>/dev/null || true
    sleep 20
}

# --- Test 1: Karpenter plumbing --------------------------------------------
# Provisions a nested-virt-capable NodeClaim and verifies the pod sees
# vmx + /dev/kvm. Uses the demo workload's own NodeClaim (matched via
# NodePool ownership) so assertions are scoped to this blueprint, not to
# any other pool on the cluster.
test_karpenter_plumbing() {
    log_test "=== Test 1: Karpenter plumbing (nested-virt family + vmx + /dev/kvm) ==="

    render_manifest
    kubectl apply -f /tmp/nested-virt-rendered.yaml
    kubectl apply -f workload.yaml

    if ! wait_for_pod_ready "app=nested-virt-demo" "$TIMEOUT_NODE_READY"; then
        log_error "FAILED: nested-virt-demo pod did not become Ready"
        return 1
    fi

    local pod node instance_type instance_id nested flag
    pod=$(kubectl get pod -l app=nested-virt-demo -o jsonpath='{.items[0].metadata.name}')
    node=$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')
    instance_type=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')

    # Scope check: the node must be owned by *this* blueprint's NodePool.
    local nodeclaim_pool
    nodeclaim_pool=$(kubectl get nodeclaims -o jsonpath="{range .items[?(@.status.nodeName==\"$node\")]}{.metadata.labels['karpenter\.sh/nodepool']}{end}" 2>/dev/null || echo "")
    if [ "$nodeclaim_pool" != "nested-virt" ]; then
        log_error "FAILED: pod landed on node '$node' whose NodeClaim is owned by pool '$nodeclaim_pool' (expected nested-virt)"
        return 1
    fi
    log_test "PASSED: pod landed on NodeClaim owned by nested-virt NodePool"

    log_info "Instance type: $instance_type"
    # Must match the instance-family list in nested-virtualization.yaml's
    # NodePool. Keep these two in sync if AWS adds more nested-virt families.
    case "$instance_type" in
        c8i*|m8i*|r8i*|x8i*|c7i*|m7i*|r7i*|i7i*)
            log_test "PASSED: instance is from a nested-virt-capable family"
            ;;
        *)
            log_error "FAILED: instance $instance_type is not from a nested-virt-capable family"
            return 1
            ;;
    esac

    # Informational: EC2 API CpuOptions. On *8i* the Nitro System passes CPU
    # virt extensions natively, so this can be reported as None even when
    # nested virt is working. The vmx + /dev/kvm checks below are the proof.
    instance_id=$(kubectl get node "$node" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
    nested=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].CpuOptions.NestedVirtualization' \
        --output text 2>/dev/null || echo "None")
    log_info "EC2 CpuOptions.NestedVirtualization for $instance_id: $nested (informational)"

    local failures=0
    flag=$(kubectl exec "$pod" -- grep -om1 'vmx\|svm' /proc/cpuinfo 2>/dev/null || echo "")
    if [ -n "$flag" ]; then
        log_test "PASSED: pod sees CPU virt extension: $flag"
    else
        log_error "FAILED: no vmx or svm flag in /proc/cpuinfo"
        failures=$((failures + 1))
    fi

    if kubectl exec "$pod" -- test -e /dev/kvm 2>/dev/null; then
        log_test "PASSED: /dev/kvm is present inside the pod"
    else
        log_error "FAILED: /dev/kvm not present inside the pod"
        failures=$((failures + 1))
    fi

    if [ $failures -gt 0 ]; then
        log_error "$failures verification check(s) failed"
        return 1
    fi
    return 0
}

# --- Test 2: Kata MicroVM boundary -----------------------------------------
# Runs a pod via RuntimeClass kata-qemu-runtime-rs and asserts the guest
# kernel differs from the host node's kernel. Different kernels = different
# VMs = the MicroVM boundary is real.
test_kata_microvm() {
    log_test "=== Test 2: Kata MicroVM boundary (guest kernel != host kernel) ==="

    kubectl apply -f sandbox-workload.yaml

    # kata-verify has restartPolicy=Never so it goes Running then Succeeded.
    if ! wait_for_pod_phase "kata-verify" "Running Succeeded" "$TIMEOUT_NODE_READY"; then
        log_error "FAILED: kata-verify pod did not run"
        return 1
    fi

    # Scope check: kata-verify must be on a nested-virt NodePool NodeClaim.
    local node nodeclaim_pool
    node=$(kubectl get pod kata-verify -o jsonpath='{.spec.nodeName}')
    nodeclaim_pool=$(kubectl get nodeclaims -o jsonpath="{range .items[?(@.status.nodeName==\"$node\")]}{.metadata.labels['karpenter\.sh/nodepool']}{end}" 2>/dev/null || echo "")
    if [ "$nodeclaim_pool" != "nested-virt" ]; then
        log_error "FAILED: kata-verify landed on '$node' owned by pool '$nodeclaim_pool' (expected nested-virt)"
        return 1
    fi

    # Host kernel: read from a non-Kata pod that sits directly on the same
    # node. workload.yaml's nested-virt-demo pod fits: it's privileged, not
    # wrapped in Kata. This gives us the host kernel identity without needing
    # SSH onto the node.
    local host_kernel
    host_kernel=$(kubectl exec deploy/nested-virt-demo -- uname -r 2>/dev/null | tr -d '\r\n' || echo "")
    if [ -z "$host_kernel" ]; then
        log_error "FAILED: could not read host kernel from nested-virt-demo pod"
        return 1
    fi
    log_info "Host kernel (from non-Kata pod on nested-virt node): $host_kernel"

    # Guest kernel: kata-verify's stdout, which runs `uname -a`.
    local guest_kernel
    guest_kernel=$(kubectl logs kata-verify 2>/dev/null | grep -oE 'Linux [^ ]+ [^ ]+' | awk '{print $3}' | head -1)
    if [ -z "$guest_kernel" ]; then
        log_error "FAILED: could not parse guest kernel from kata-verify logs"
        kubectl logs kata-verify 2>/dev/null | tail -20 || true
        return 1
    fi
    log_info "Guest kernel (from inside Kata MicroVM):             $guest_kernel"

    if [ "$host_kernel" = "$guest_kernel" ]; then
        log_error "FAILED: guest kernel == host kernel; Kata isn't wrapping the pod"
        return 1
    fi
    log_test "PASSED: guest kernel differs from host kernel, MicroVM boundary confirmed"
    return 0
}

# --- Test 3: Agent sandbox demo --------------------------------------------
# Deploys the sandbox Deployment, POSTs a snippet of Python to /exec, and
# checks that the kernel reported in the response is the Kata guest kernel
# (i.e. not the host kernel).
test_sandbox_exec() {
    log_test "=== Test 3: Agent sandbox exec (POSTed code runs inside MicroVM) ==="

    kubectl apply -f sandbox.yaml
    if ! wait_for_pod_ready "app=sandbox" "$TIMEOUT_NODE_READY"; then
        log_error "FAILED: sandbox pod did not become Ready"
        return 1
    fi

    # Scope check: the sandbox pod must be on a nested-virt NodeClaim.
    local sandbox_pod node nodeclaim_pool
    sandbox_pod=$(kubectl get pod -l app=sandbox -o jsonpath='{.items[0].metadata.name}')
    node=$(kubectl get pod "$sandbox_pod" -o jsonpath='{.spec.nodeName}')
    nodeclaim_pool=$(kubectl get nodeclaims -o jsonpath="{range .items[?(@.status.nodeName==\"$node\")]}{.metadata.labels['karpenter\.sh/nodepool']}{end}" 2>/dev/null || echo "")
    if [ "$nodeclaim_pool" != "nested-virt" ]; then
        log_error "FAILED: sandbox pod landed on '$node' owned by pool '$nodeclaim_pool' (expected nested-virt)"
        return 1
    fi

    # Fire a POST from inside a pod on the cluster. Using `kubectl exec` on
    # the sandbox pod itself with a stdlib urllib call avoids the
    # `kubectl run --rm -i` pattern (which is unreliable in non-TTY shells)
    # and doesn't need a second image with curl baked in. The sandbox
    # container is python:3.12-slim, so urllib is available.
    log_info "Calling POST /exec against sandbox service..."
    local resp
    resp=$(kubectl exec "$sandbox_pod" -- python3 -c "
import urllib.request, json
req = urllib.request.Request(
    'http://localhost:8080/exec',
    data=json.dumps({'code': 'import os; print(os.uname().release)'}).encode(),
    headers={'Content-Type': 'application/json'},
)
print(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null || echo "")

    if [ -z "$resp" ]; then
        log_error "FAILED: sandbox /exec returned no response"
        return 1
    fi
    log_info "Sandbox response: $resp"

    # Parse the exec'd code's stdout. That's the kernel the *guest* sees.
    local exec_kernel
    exec_kernel=$(echo "$resp" | grep -oE '"stdout":[[:space:]]*"[^"\\]*' | head -1 | sed -E 's/.*"stdout":[[:space:]]*"([^\\]*).*/\1/' | tr -d '\r\n')
    if [ -z "$exec_kernel" ]; then
        log_error "FAILED: could not parse stdout kernel from sandbox response"
        return 1
    fi

    local host_kernel
    host_kernel=$(kubectl exec deploy/nested-virt-demo -- uname -r 2>/dev/null | tr -d '\r\n' || echo "")

    log_info "Kernel reported by exec'd code inside sandbox: $exec_kernel"
    log_info "Host kernel on nested-virt node:               $host_kernel"

    if [ "$exec_kernel" = "$host_kernel" ]; then
        log_error "FAILED: exec'd code sees the host kernel; sandbox is not isolated"
        return 1
    fi
    log_test "PASSED: POSTed code executed inside the MicroVM (kernel differs from host)"

    # --- Sub-test: destructive rm inside the sandbox ---
    # Mirror the README's `== destructive rm ==` example. POST a single
    # Python snippet that creates a marker file, deletes it with `rm -rf`,
    # and reports the before/after existence. If we get back
    # `before=True after=False` with exit_code=0, the rm executed inside
    # the sandbox's MicroVM filesystem. The host node's /tmp is unaffected
    # because it's on the other side of the VM boundary.
    log_info "Running destructive rm sub-test via sandbox /exec..."

    local destructive_code='p="/tmp/sandbox-rm-marker"; open(p,"w").write("present"); import os, subprocess; before=os.path.exists(p); subprocess.run(["rm","-rf",p], check=False); after=os.path.exists(p); print(f"before={before} after={after}")'
    local rm_resp
    rm_resp=$(kubectl exec "$sandbox_pod" -- python3 -c "
import urllib.request, json
req = urllib.request.Request(
    'http://localhost:8080/exec',
    data=json.dumps({'code': '''$destructive_code'''}).encode(),
    headers={'Content-Type': 'application/json'},
)
print(urllib.request.urlopen(req, timeout=15).read().decode())
" 2>/dev/null || echo "")

    if [ -z "$rm_resp" ]; then
        log_error "FAILED: destructive rm sub-test /exec returned no response"
        return 1
    fi
    log_info "Destructive rm sub-test response: $rm_resp"

    # The response's stdout should contain "before=True after=False".
    # exit_code must be 0 and stderr empty.
    if ! echo "$rm_resp" | grep -q '"exit_code":[[:space:]]*0'; then
        log_error "FAILED: destructive rm returned non-zero exit_code"
        return 1
    fi
    if ! echo "$rm_resp" | grep -q 'before=True[[:space:]]*after=False'; then
        log_error "FAILED: sandbox filesystem not mutated as expected. Response was: $rm_resp"
        return 1
    fi
    log_test "PASSED: destructive rm ran inside the sandbox MicroVM (marker created, then removed)"

    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    test_karpenter_plumbing || exit_code=1
    if [ $exit_code -eq 0 ]; then
        test_kata_microvm || exit_code=1
    fi
    if [ $exit_code -eq 0 ]; then
        test_sandbox_exec || exit_code=1
    fi
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
