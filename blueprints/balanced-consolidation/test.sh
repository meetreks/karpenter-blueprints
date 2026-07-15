#!/bin/bash
# Test script for the Balanced Consolidation blueprint.
# Validates the two behaviors that are deterministically observable on a
# small test cluster:
#   1. Empty-node consolidation still fires under Balanced (fast path,
#      no scoring — same as WhenEmpty).
#   2. Feasibility check rejects consolidation when no cheaper replacement
#      is available (Unconsolidatable event).
#
# The full scoring behavior (karpenter_consolidation_score /
# karpenter_consolidation_moves_total metrics, ConsolidationApproved
# events) requires a cluster with diverse Karpenter capacity so that a
# feasible replace-with-cheaper action exists. That's covered in the
# README's Results section as a manual observation.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.14+ installed (Balanced requires this)
# - An EC2NodeClass named "default" (or set VARIANT=automode for EKS Auto Mode)
#
# Usage:
#   ./test.sh              # self-managed Karpenter (default)
#   VARIANT=automode ./test.sh  # EKS Auto Mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test configuration
VARIANT=${VARIANT:-oss}
TIMEOUT_NODE_READY=300       # 5 min for Karpenter to provision + register
TIMEOUT_CONSOLIDATION=180    # 3 min for consolidation to fire after scale-down
POLL_INTERVAL=10

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites (variant: $VARIANT)..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Verify the NodePool CRD supports 'Balanced' (Karpenter v1.14+).
    local supported
    supported=$(kubectl get crd nodepools.karpenter.sh -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.disruption.properties.consolidationPolicy.enum}' 2>/dev/null || echo "")
    if [[ "$supported" != *"Balanced"* ]]; then
        log_error "NodePool CRD does not list 'Balanced' as a valid consolidationPolicy."
        log_error "This blueprint requires Karpenter v1.14 or later."
        exit 1
    fi

    log_info "Prerequisites check passed (Balanced is a valid consolidationPolicy)"
}

wait_for_nodeclaim_ready() {
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0
    log_info "Waiting for at least one NodeClaim to become Ready (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        # Query the Ready condition directly via jsonpath to avoid column parsing.
        local ready_count
        ready_count=$(kubectl get nodeclaims -o jsonpath='{range .items[*].status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}' 2>/dev/null | grep -c "^True$" || true)
        ready_count=$((ready_count + 0))
        if [ "$ready_count" -ge 1 ]; then
            log_info "NodeClaim is Ready ($ready_count total)"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for NodeClaim to become Ready"
    kubectl get nodeclaims 2>/dev/null || true
    return 1
}

wait_for_no_nodeclaims() {
    local timeout=$TIMEOUT_CONSOLIDATION
    local elapsed=0
    log_info "Waiting for all NodeClaims to be consolidated away (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
        count=$((count + 0))
        if [ "$count" -eq 0 ]; then
            log_info "All NodeClaims removed"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for consolidation"
    kubectl get nodeclaims 2>/dev/null || true
    return 1
}

apply_nodepool() {
    if [ "$VARIANT" = "automode" ]; then
        log_info "Applying EKS Auto Mode NodePool..."
        kubectl apply -f balanced-consolidation-automode.yaml
    else
        log_info "Applying self-managed Karpenter NodePool..."
        kubectl apply -f balanced-consolidation.yaml
    fi

    # Verify the policy is set as expected.
    local policy
    policy=$(kubectl get nodepool default -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null || echo "")
    if [ "$policy" != "Balanced" ]; then
        log_error "NodePool default is not on Balanced policy (got: '$policy')"
        return 1
    fi
    log_info "NodePool default consolidationPolicy: $policy"
}

cleanup() {
    log_info "Cleaning up workloads..."
    kubectl delete pdb inflate-pdb --ignore-not-found=true 2>/dev/null || true
    kubectl delete deployment inflate inflate-lowpri inflate-highpri --ignore-not-found=true 2>/dev/null || true
    kubectl delete priorityclass karpenter-blueprint-low karpenter-blueprint-high --ignore-not-found=true 2>/dev/null || true
    # Give Karpenter time to consolidate any empty nodes we left behind.
    sleep 30
}

test_empty_node_consolidation() {
    log_test "=== Test 1: Empty-node consolidation still fires under Balanced ==="

    kubectl apply -f workload.yaml
    log_info "Scaling inflate to 5 replicas to force Karpenter to provision..."
    kubectl scale deployment inflate --replicas=5

    if ! wait_for_nodeclaim_ready; then
        log_error "❌ FAILED: Karpenter did not provision a node"
        return 1
    fi

    log_info "Scaling inflate back to 0 (nodes should be empty, then consolidated)..."
    kubectl scale deployment inflate --replicas=0

    if ! wait_for_no_nodeclaims; then
        log_error "❌ FAILED: Empty node was not consolidated within timeout"
        return 1
    fi

    log_test "✅ PASSED: Empty-node consolidation fired and NodeClaim was removed"
    return 0
}

test_feasibility_rejects_replace() {
    log_test "=== Test 2: Feasibility check rejects when no cheaper replacement exists ==="

    # Cleanup from Test 1 removes the deployments; re-apply the workload.
    kubectl apply -f workload.yaml

    log_info "Applying a PodDisruptionBudget that blocks pod evictions..."
    cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: inflate-pdb
spec:
  minAvailable: 100%
  selector:
    matchLabels:
      app: inflate
EOF

    log_info "Scaling inflate to 5 replicas (pods will be sticky due to PDB)..."
    kubectl scale deployment inflate --replicas=5
    if ! wait_for_nodeclaim_ready; then
        log_error "❌ FAILED: Karpenter did not provision a node"
        return 1
    fi

    # Give Karpenter time to evaluate consolidation and hit the feasibility check.
    # The blueprint's default consolidateAfter is 30s; we wait 90s to be safe.
    log_info "Waiting 90s for Karpenter to attempt consolidation..."
    sleep 90

    # Look for Unconsolidatable events. Either the message about not being able to
    # replace with a cheaper node OR PDB blocking eviction is a valid outcome —
    # both mean the feasibility check ran and rejected the action before scoring.
    local events
    events=$(kubectl get events --field-selector reason=Unconsolidatable -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null || echo "")
    if [ -z "$events" ]; then
        log_error "❌ FAILED: No Unconsolidatable events emitted — expected feasibility rejection"
        kubectl get events --field-selector reason=Unconsolidatable 2>/dev/null || true
        return 1
    fi
    log_info "Unconsolidatable events observed:"
    echo "$events" | sort -u | sed 's/^/  - /'

    # Verify the NodeClaim was NOT removed.
    local count
    count=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        log_error "❌ FAILED: NodeClaim was removed despite feasibility rejection"
        return 1
    fi

    log_test "✅ PASSED: Feasibility check rejected the consolidation ($count NodeClaim(s) preserved)"
    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    apply_nodepool || { log_error "Failed to apply NodePool"; exit 1; }

    # Ensure a clean start.
    cleanup

    test_empty_node_consolidation || exit_code=1
    cleanup

    test_feasibility_rejects_replace || exit_code=1
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
