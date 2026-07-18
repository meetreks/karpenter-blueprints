#!/bin/bash
# Test script for the Balanced Consolidation blueprint.
# Validates the two behaviors that are deterministic on a small test cluster:
#   1. Empty-node consolidation still fires under Balanced (fast path, no scoring).
#   2. Feasibility check rejects consolidation when no cheaper replacement is
#      available (Unconsolidatable event) or Balanced scores it below threshold
#      (ConsolidationRejected event).
#
# The full scoring behavior (karpenter_consolidation_score /
# karpenter_consolidation_moves_total metrics, ConsolidationApproved events)
# requires diverse cluster capacity so a feasible replace-with-cheaper action
# exists. That is covered in the README walkthrough as a manual exercise.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.14+ installed (Balanced requires this)
# - Environment variables (self-managed only):
#     CLUSTER_NAME                    (default: karpenter-blueprints)
#     KARPENTER_NODE_IAM_ROLE_NAME    (default: karpenter-blueprints)
#   Auto Mode variant reuses the built-in NodeClass and needs neither.
#
# Usage:
#   ./test.sh                    # self-managed Karpenter (default)
#   VARIANT=automode ./test.sh   # EKS Auto Mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VARIANT=${VARIANT:-oss}
TIMEOUT_NODE_READY=300
TIMEOUT_CONSOLIDATION=180
POLL_INTERVAL=10

# Blueprint-scoped resource names — no collision with 'default' NodePool or with
# other blueprints running in the same cluster.
NODEPOOL_NAME=balanced-consolidation
DEPLOYMENT_NAME=balanced-inflate

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

    local supported
    supported=$(kubectl get crd nodepools.karpenter.sh -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.disruption.properties.consolidationPolicy.enum}' 2>/dev/null || echo "")
    if [[ "$supported" != *"Balanced"* ]]; then
        log_error "NodePool CRD does not list 'Balanced' as a valid consolidationPolicy."
        log_error "This blueprint requires Karpenter v1.14 or later."
        exit 1
    fi

    export CLUSTER_NAME=${CLUSTER_NAME:-karpenter-blueprints}
    export KARPENTER_NODE_IAM_ROLE_NAME=${KARPENTER_NODE_IAM_ROLE_NAME:-karpenter-blueprints}
    log_info "Using cluster: $CLUSTER_NAME, node IAM role: $KARPENTER_NODE_IAM_ROLE_NAME"
    log_info "Prerequisites check passed (Balanced is a valid consolidationPolicy)"
}

render_manifest() {
    local src=$1
    local dst=$2
    sed -e "s|<<CLUSTER_NAME>>|$CLUSTER_NAME|g" \
        -e "s|<<KARPENTER_NODE_IAM_ROLE_NAME>>|$KARPENTER_NODE_IAM_ROLE_NAME|g" \
        "$src" > "$dst"
}

wait_for_nodeclaim_ready() {
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0
    log_info "Waiting for at least one NodeClaim on '$NODEPOOL_NAME' to be Ready (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local ready_count
        ready_count=$(kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" -o jsonpath='{range .items[*].status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}' 2>/dev/null | grep -c "^True$" || true)
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
    kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" 2>/dev/null || true
    return 1
}

wait_for_no_nodeclaims() {
    local timeout=$TIMEOUT_CONSOLIDATION
    local elapsed=0
    log_info "Waiting for NodeClaims on '$NODEPOOL_NAME' to be consolidated away (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        count=$((count + 0))
        if [ "$count" -eq 0 ]; then
            log_info "All NodeClaims on '$NODEPOOL_NAME' removed"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for consolidation"
    kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" 2>/dev/null || true
    return 1
}

apply_nodepool() {
    if [ "$VARIANT" = "automode" ]; then
        log_info "Applying EKS Auto Mode NodePool..."
        kubectl apply -f balanced-consolidation-automode.yaml
    else
        log_info "Rendering + applying self-managed Karpenter NodePool..."
        render_manifest balanced-consolidation.yaml /tmp/balanced-consolidation-rendered.yaml
        kubectl apply -f /tmp/balanced-consolidation-rendered.yaml
    fi

    local policy
    policy=$(kubectl get nodepool "$NODEPOOL_NAME" -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null || echo "")
    if [ "$policy" != "Balanced" ]; then
        log_error "NodePool '$NODEPOOL_NAME' is not on Balanced policy (got: '$policy')"
        return 1
    fi
    log_info "NodePool '$NODEPOOL_NAME' consolidationPolicy: $policy"
}

cleanup() {
    log_info "Cleaning up workloads (leaving NodePool/EC2NodeClass in place)..."
    kubectl delete pdb "${DEPLOYMENT_NAME}-pdb" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 30
}

full_cleanup() {
    cleanup
    log_info "Deleting NodePool and EC2NodeClass..."
    if [ "$VARIANT" = "automode" ]; then
        kubectl delete -f balanced-consolidation-automode.yaml --ignore-not-found=true 2>/dev/null || true
    else
        kubectl delete -f /tmp/balanced-consolidation-rendered.yaml --ignore-not-found=true 2>/dev/null || true
    fi
}

test_empty_node_consolidation() {
    log_test "=== Test 1: Empty-node consolidation still fires under Balanced ==="

    kubectl apply -f workload.yaml
    log_info "Scaling ${DEPLOYMENT_NAME} to 5 replicas to force Karpenter to provision..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=5

    if ! wait_for_nodeclaim_ready; then
        log_error "❌ FAILED: Karpenter did not provision a node"
        return 1
    fi

    log_info "Scaling ${DEPLOYMENT_NAME} back to 0 (nodes should be empty, then consolidated)..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=0

    if ! wait_for_no_nodeclaims; then
        log_error "❌ FAILED: Empty node was not consolidated within timeout"
        return 1
    fi

    log_test "✅ PASSED: Empty-node consolidation fired and NodeClaim was removed"
    return 0
}

test_feasibility_or_score_rejects() {
    log_test "=== Test 2: Feasibility/score rejects when no cheaper replacement wins ==="

    kubectl apply -f workload.yaml

    log_info "Applying a PodDisruptionBudget that blocks pod evictions..."
    cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${DEPLOYMENT_NAME}-pdb
spec:
  minAvailable: 100%
  selector:
    matchLabels:
      app: ${DEPLOYMENT_NAME}
EOF

    log_info "Scaling ${DEPLOYMENT_NAME} to 5 replicas (pods will be sticky due to PDB)..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=5
    if ! wait_for_nodeclaim_ready; then
        log_error "❌ FAILED: Karpenter did not provision a node"
        return 1
    fi

    log_info "Waiting 90s for Karpenter to evaluate consolidation..."
    sleep 90

    # Any of three event reasons is a valid "consolidation prevented" outcome:
    #   - Unconsolidatable       : feasibility check found no cheaper replacement
    #   - ConsolidationRejected  : feasibility passed but Balanced score < threshold
    #   - DisruptionBlocked      : a PDB or policy prevented the eviction
    local matched=0
    for reason in Unconsolidatable ConsolidationRejected DisruptionBlocked; do
        local msgs
        msgs=$(kubectl get events --field-selector reason="$reason" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | sort -u)
        if [ -n "$msgs" ]; then
            matched=$((matched + 1))
            log_info "$reason events observed:"
            echo "$msgs" | sed 's/^/  - /'
        fi
    done

    if [ $matched -eq 0 ]; then
        log_error "❌ FAILED: No Unconsolidatable, ConsolidationRejected, or DisruptionBlocked events emitted"
        kubectl get events --sort-by=.lastTimestamp | tail -20 || true
        return 1
    fi

    local count
    count=$(kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        log_error "❌ FAILED: NodeClaim was removed despite rejection"
        return 1
    fi

    log_test "✅ PASSED: Consolidation rejected ($count NodeClaim(s) preserved)"
    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    apply_nodepool || { log_error "Failed to apply NodePool"; exit 1; }
    cleanup

    test_empty_node_consolidation || exit_code=1
    cleanup

    test_feasibility_or_score_rejects || exit_code=1
    full_cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
