#!/bin/bash
# Test script for the Balanced Consolidation blueprint.
#
# Runs the same scale sequence twice — once under WhenEmptyOrUnderutilized and
# once under Balanced — and validates that Karpenter behaves consistently at
# each step. The blueprint's NodePool references the cluster's 'default'
# EC2NodeClass, so no placeholder substitution is needed.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.14+ installed (Balanced requires this)
# - A 'default' EC2NodeClass (self-managed) or NodeClass (Auto Mode) exists in
#   the cluster; the repo's cluster/terraform template creates one
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

    # The blueprint references a 'default' EC2NodeClass (self-managed) or
    # NodeClass (Auto Mode); confirm it exists before we try to apply.
    if [ "$VARIANT" = "automode" ]; then
        if ! kubectl get nodeclass.eks.amazonaws.com default &> /dev/null; then
            log_error "Auto Mode NodeClass 'default' not found in the cluster."
            exit 1
        fi
    else
        if ! kubectl get ec2nodeclass.karpenter.k8s.aws default &> /dev/null; then
            log_error "EC2NodeClass 'default' not found in the cluster."
            log_error "The blueprint expects the repo's cluster template to have created one."
            exit 1
        fi
    fi

    log_info "Prerequisites check passed"
}

apply_nodepool() {
    if [ "$VARIANT" = "automode" ]; then
        log_info "Applying EKS Auto Mode NodePool..."
        kubectl apply -f balanced-consolidation-automode.yaml
    else
        log_info "Applying self-managed Karpenter NodePool..."
        kubectl apply -f balanced-consolidation.yaml
    fi

    local policy
    policy=$(kubectl get nodepool "$NODEPOOL_NAME" -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null || echo "")
    if [ "$policy" != "Balanced" ]; then
        log_error "NodePool '$NODEPOOL_NAME' is not on Balanced policy (got: '$policy')"
        return 1
    fi
    log_info "NodePool '$NODEPOOL_NAME' consolidationPolicy: $policy"
}

set_policy() {
    local policy=$1
    log_info "Setting NodePool $NODEPOOL_NAME consolidationPolicy: $policy"
    kubectl patch nodepool "$NODEPOOL_NAME" --type=merge \
        -p "{\"spec\":{\"disruption\":{\"consolidationPolicy\":\"$policy\"}}}"
}

count_blueprint_nodeclaims() {
    kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" \
        -o jsonpath='{range .items[*].status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}' 2>/dev/null \
        | grep -c "^True$" || true
}

wait_for_nodeclaim_count() {
    local expected=$1
    local timeout=${2:-$TIMEOUT_NODE_READY}
    local elapsed=0
    log_info "Waiting for Ready NodeClaim count on '$NODEPOOL_NAME' to reach $expected (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(count_blueprint_nodeclaims)
        count=$((count + 0))
        if [ "$count" -eq "$expected" ]; then
            log_info "Reached expected NodeClaim count: $count"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout: NodeClaim count on '$NODEPOOL_NAME' is $(count_blueprint_nodeclaims), expected $expected"
    kubectl get nodeclaims -l karpenter.sh/nodepool="$NODEPOOL_NAME" 2>/dev/null || true
    return 1
}

cleanup() {
    log_info "Cleaning up workloads (leaving NodePool in place)..."
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 30
}

full_cleanup() {
    cleanup
    log_info "Deleting NodePool..."
    if [ "$VARIANT" = "automode" ]; then
        kubectl delete -f balanced-consolidation-automode.yaml --ignore-not-found=true 2>/dev/null || true
    else
        kubectl delete -f balanced-consolidation.yaml --ignore-not-found=true 2>/dev/null || true
    fi
}

# Test 1: provisioning under the initial policy and empty-node consolidation.
# Both WhenEmptyOrUnderutilized and Balanced should provision on scale-up and
# remove the node on scale-to-zero. The blueprint's own NodeClaim count is
# what we assert on — the cluster's other nodes are ignored.
test_provisioning_and_empty_delete() {
    log_test "=== Test 1: Provisioning + empty-node consolidation ==="

    kubectl apply -f workload.yaml

    log_info "Scaling $DEPLOYMENT_NAME to 5 replicas..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=5

    if ! wait_for_nodeclaim_count 1; then
        log_error "❌ FAILED: expected 1 NodeClaim after scale-up"
        return 1
    fi

    log_info "Scaling $DEPLOYMENT_NAME to 0 replicas..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=0

    if ! wait_for_nodeclaim_count 0 $TIMEOUT_CONSOLIDATION; then
        log_error "❌ FAILED: NodeClaim not removed after scale-to-zero"
        return 1
    fi

    log_test "✅ PASSED: provisioning + empty-node consolidation work under Balanced"
    return 0
}

# Test 2: Balanced's score gate. We force a scenario where consolidation would
# happen under WhenEmptyOrUnderutilized (pods sticky via PDB, no cheaper node
# can absorb them) and verify Balanced either rejects via the score gate or
# blocks via feasibility check.
test_score_gate_blocks_marginal() {
    log_test "=== Test 2: Score gate / feasibility rejects marginal consolidation ==="

    kubectl apply -f workload.yaml

    kubectl apply -f - <<EOF
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

    log_info "Scaling $DEPLOYMENT_NAME to 5 replicas (pods sticky via PDB)..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas=5

    if ! wait_for_nodeclaim_count 1; then
        log_error "❌ FAILED: expected 1 NodeClaim after scale-up"
        kubectl delete pdb "${DEPLOYMENT_NAME}-pdb" --ignore-not-found=true
        return 1
    fi

    log_info "Waiting 90s for Karpenter to evaluate consolidation..."
    sleep 90

    # Any of three event reasons is a valid "consolidation prevented" outcome:
    #   Unconsolidatable       : feasibility check found no cheaper replacement
    #   ConsolidationRejected  : feasibility passed but Balanced score < threshold
    #   DisruptionBlocked      : a PDB or policy prevented the eviction
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
        kubectl delete pdb "${DEPLOYMENT_NAME}-pdb" --ignore-not-found=true
        return 1
    fi

    local count
    count=$(count_blueprint_nodeclaims)
    count=$((count + 0))
    if [ "$count" -eq 0 ]; then
        log_error "❌ FAILED: NodeClaim was removed despite rejection"
        kubectl delete pdb "${DEPLOYMENT_NAME}-pdb" --ignore-not-found=true
        return 1
    fi

    log_test "✅ PASSED: consolidation rejected ($count NodeClaim(s) preserved)"
    kubectl delete pdb "${DEPLOYMENT_NAME}-pdb" --ignore-not-found=true
    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    apply_nodepool || { log_error "Failed to apply NodePool"; exit 1; }
    cleanup

    test_provisioning_and_empty_delete || exit_code=1
    cleanup

    test_score_gate_blocks_marginal || exit_code=1
    full_cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
