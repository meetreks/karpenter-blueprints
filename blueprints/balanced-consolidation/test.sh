#!/bin/bash
# Test script for the Balanced Consolidation blueprint.
#
# Automates the four scenarios described in README.md — provisioning,
# replace-transition, priority-weighted, and score-gate — under the Balanced
# consolidation policy. Every assertion is scoped to NodeClaims owned by this
# blueprint's NodePool (label karpenter.sh/nodepool=balanced-consolidation)
# and, for events, to a specific NodeClaim by name. Activity on unrelated
# NodePools in the cluster cannot affect test outcomes.
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter v1.14 or later installed (self-managed OSS). The Balanced policy
#   is not yet available on EKS Auto Mode; see README.md "Requirements".
# - A 'default' EC2NodeClass exists (the repo's cluster/terraform template
#   creates one)
#
# Usage:
#   ./test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TIMEOUT_NODE_READY=300
TIMEOUT_CONSOLIDATION=240
POLL_INTERVAL=10

NODEPOOL_NAME=balanced-consolidation
BASELINE_DEPLOY=balanced-inflate
LOWPRI_DEPLOY=balanced-inflate-lowpri
HIGHPRI_DEPLOY=balanced-inflate-highpri
NODECLAIM_SELECTOR="karpenter.sh/nodepool=$NODEPOOL_NAME"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test()  { echo -e "${GREEN}[TEST]${NC} $1"; }

# --- Blueprint-scoped helpers ------------------------------------------------

# Lists NodeClaim names for this blueprint's NodePool, one per line.
list_blueprint_nodeclaims() {
    kubectl get nodeclaims -l "$NODECLAIM_SELECTOR" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true
}

# Number of NodeClaims currently in Ready=True.
count_ready_nodeclaims() {
    local n
    n=$(kubectl get nodeclaims -l "$NODECLAIM_SELECTOR" \
        -o jsonpath='{range .items[*].status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}' 2>/dev/null \
        | grep -c "^True$" || true)
    echo "$((n + 0))"
}

# Instance type of a NodeClaim, read from its label.
nodeclaim_instance_type() {
    kubectl get nodeclaim "$1" \
        -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null
}

# Events emitted against a specific NodeClaim by reason.
nodeclaim_events_by_reason() {
    local claim=$1
    local reason=$2
    kubectl get events \
        --field-selector "involvedObject.kind=NodeClaim,involvedObject.name=$claim,reason=$reason" \
        -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | sort -u
}

# NodeClaim currently hosting the pods of a given deployment.
nodeclaim_for_deployment() {
    local deploy=$1
    local node
    node=$(kubectl get pods -l app="$deploy" \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
    if [ -z "$node" ]; then
        return 1
    fi
    kubectl get nodeclaims -l "$NODECLAIM_SELECTOR" \
        -o jsonpath="{range .items[?(@.status.nodeName==\"$node\")]}{.metadata.name}{end}" 2>/dev/null
}

# Waits for the blueprint's Ready NodeClaim count to reach $1 within $2 seconds.
wait_for_nodeclaim_count() {
    local expected=$1
    local timeout=${2:-$TIMEOUT_NODE_READY}
    local elapsed=0
    log_info "Waiting for Ready NodeClaim count on '$NODEPOOL_NAME' to reach $expected (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(count_ready_nodeclaims)
        if [ "$count" -eq "$expected" ]; then
            log_info "Reached expected NodeClaim count: $count"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""
    log_error "Timeout: NodeClaim count on '$NODEPOOL_NAME' is $(count_ready_nodeclaims), expected $expected"
    kubectl get nodeclaims -l "$NODECLAIM_SELECTOR" 2>/dev/null || true
    return 1
}

# --- Setup / teardown --------------------------------------------------------

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    local supported
    supported=$(kubectl get crd nodepools.karpenter.sh \
        -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.disruption.properties.consolidationPolicy.enum}' 2>/dev/null || echo "")
    if [[ "$supported" != *"Balanced"* ]]; then
        log_error "NodePool CRD does not list 'Balanced' as a valid consolidationPolicy."
        log_error "This blueprint requires Karpenter v1.14 or later (OSS, self-managed)."
        log_error "EKS Auto Mode is not yet supported."
        exit 1
    fi

    if ! kubectl get ec2nodeclass.karpenter.k8s.aws default &> /dev/null; then
        log_error "EC2NodeClass 'default' not found in the cluster."
        log_error "The blueprint expects the repo's cluster template to have created one."
        exit 1
    fi

    log_info "Prerequisites check passed"
}

apply_nodepool() {
    log_info "Applying NodePool and workloads..."
    kubectl apply -f balanced-consolidation.yaml
    kubectl apply -f workload.yaml

    local policy
    policy=$(kubectl get nodepool "$NODEPOOL_NAME" -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null || echo "")
    if [ "$policy" != "Balanced" ]; then
        log_error "NodePool '$NODEPOOL_NAME' is not on Balanced policy (got: '$policy')"
        return 1
    fi
    log_info "NodePool '$NODEPOOL_NAME' consolidationPolicy: $policy"
}

# Scales all blueprint deployments to 0 and waits for the pool to drain.
reset_state() {
    log_info "Resetting: scaling all deployments to 0 and waiting for NodeClaims to drain..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=0 --timeout=30s 2>/dev/null || true
    kubectl scale deployment "$LOWPRI_DEPLOY"   --replicas=0 --timeout=30s 2>/dev/null || true
    kubectl scale deployment "$HIGHPRI_DEPLOY"  --replicas=0 --timeout=30s 2>/dev/null || true
    kubectl delete pdb "${BASELINE_DEPLOY}-pdb" --ignore-not-found=true 2>/dev/null || true
    wait_for_nodeclaim_count 0 $TIMEOUT_CONSOLIDATION || {
        log_warn "Reset did not fully drain within timeout; continuing anyway"
    }
}

full_cleanup() {
    log_info "Cleaning up workloads and NodePool..."
    kubectl delete -f workload.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete pdb "${BASELINE_DEPLOY}-pdb" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f balanced-consolidation.yaml --ignore-not-found=true 2>/dev/null || true
}

# --- Tests -------------------------------------------------------------------

# Test 1: provisioning + empty-node consolidation.
# Scale 0->5 provisions a NodeClaim; scale 5->0 removes it via empty-node
# consolidation (which fires under any consolidationPolicy, including Balanced).
test_provisioning_and_empty_consolidation() {
    log_test "=== Test 1: Provisioning + empty-node consolidation ==="

    log_info "Scaling $BASELINE_DEPLOY to 5 replicas..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=5

    if ! wait_for_nodeclaim_count 1; then
        log_error "FAILED: expected 1 NodeClaim after scale-up to 5"
        return 1
    fi

    local claim
    claim=$(list_blueprint_nodeclaims | head -1)
    local itype
    itype=$(nodeclaim_instance_type "$claim")
    log_info "Provisioned NodeClaim $claim ($itype) for 5 replicas"

    log_info "Scaling $BASELINE_DEPLOY to 0 replicas..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=0

    if ! wait_for_nodeclaim_count 0 $TIMEOUT_CONSOLIDATION; then
        log_error "FAILED: NodeClaim not removed after scale-to-zero"
        return 1
    fi

    log_test "PASSED: provisioning + empty-node consolidation"
    return 0
}

# Test 2: replace-transition. Scaling 5->10 adds a second NodeClaim without
# replacing the first. Scaling 10->3 leaves the original oversized node idle;
# Balanced approves the replace (savings clear the score gate) and swaps it
# out for a smaller instance. We assert the original NodeClaim's name is
# gone from the pool, not merely that "some" consolidation happened.
test_replace_transition() {
    log_test "=== Test 2: Replace transition (5 -> 10 -> 3) ==="

    log_info "Scaling $BASELINE_DEPLOY to 5 replicas..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=5

    if ! wait_for_nodeclaim_count 1; then
        log_error "FAILED: expected 1 NodeClaim after scale-up to 5"
        return 1
    fi

    local original_claim
    original_claim=$(list_blueprint_nodeclaims | head -1)
    local original_type
    original_type=$(nodeclaim_instance_type "$original_claim")
    log_info "Original NodeClaim: $original_claim ($original_type)"

    log_info "Scaling $BASELINE_DEPLOY to 10 replicas..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=10

    if ! wait_for_nodeclaim_count 2; then
        log_error "FAILED: expected 2 NodeClaims after scale-up to 10"
        return 1
    fi

    # The original should still be present after scale-up (no replace happened).
    if ! list_blueprint_nodeclaims | grep -q "^${original_claim}$"; then
        log_error "FAILED: original NodeClaim $original_claim was replaced during scale-up (not expected)"
        return 1
    fi

    log_info "Scaling $BASELINE_DEPLOY to 3 replicas — expecting replace of $original_claim..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=3

    local elapsed=0
    while [ $elapsed -lt $TIMEOUT_CONSOLIDATION ]; do
        local count
        count=$(count_ready_nodeclaims)
        # Success = the original NodeClaim is no longer in the pool, and we
        # have at least one Ready NodeClaim serving the remaining 3 replicas.
        if [ "$count" -ge 1 ] && ! list_blueprint_nodeclaims | grep -q "^${original_claim}$"; then
            log_info "Original NodeClaim $original_claim ($original_type) removed"
            log_info "Current pool:"
            for c in $(list_blueprint_nodeclaims); do
                log_info "  - $c ($(nodeclaim_instance_type "$c"))"
            done
            log_test "PASSED: Balanced approved replace-transition (original $original_type node consolidated)"
            return 0
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""

    log_error "FAILED: original NodeClaim $original_claim ($original_type) still present after ${TIMEOUT_CONSOLIDATION}s"
    kubectl get nodeclaims -l "$NODECLAIM_SELECTOR"
    return 1
}

# Test 3: priority-weighted consolidation. Scale high-pri first (1 node), then
# low-pri (anti-affinity forces a second node). Record which NodeClaim hosts
# each tier, then scale low-pri to 0. We assert that the specific NodeClaim
# that hosted low-pri is the one removed, and the high-pri host is preserved.
test_priority_weighted() {
    log_test "=== Test 3: Priority-weighted consolidation ==="

    log_info "Scaling $HIGHPRI_DEPLOY to 3 replicas..."
    kubectl scale deployment "$HIGHPRI_DEPLOY" --replicas=3
    if ! wait_for_nodeclaim_count 1; then
        log_error "FAILED: expected 1 NodeClaim after high-pri scale-up"
        return 1
    fi

    # Wait for pods Ready so we can query nodeName reliably.
    kubectl rollout status deployment "$HIGHPRI_DEPLOY" --timeout=120s

    local highpri_claim
    highpri_claim=$(nodeclaim_for_deployment "$HIGHPRI_DEPLOY")
    if [ -z "$highpri_claim" ]; then
        log_error "FAILED: could not identify high-pri NodeClaim"
        return 1
    fi
    log_info "High-priority NodeClaim: $highpri_claim ($(nodeclaim_instance_type "$highpri_claim"))"

    log_info "Scaling $LOWPRI_DEPLOY to 3 replicas (anti-affinity forces a second node)..."
    kubectl scale deployment "$LOWPRI_DEPLOY" --replicas=3
    if ! wait_for_nodeclaim_count 2; then
        log_error "FAILED: expected 2 NodeClaims after low-pri scale-up"
        return 1
    fi
    kubectl rollout status deployment "$LOWPRI_DEPLOY" --timeout=120s

    local lowpri_claim
    lowpri_claim=$(nodeclaim_for_deployment "$LOWPRI_DEPLOY")
    if [ -z "$lowpri_claim" ] || [ "$lowpri_claim" = "$highpri_claim" ]; then
        log_error "FAILED: low-pri and high-pri pods co-located (anti-affinity misconfigured?)"
        log_error "  low_pri=$lowpri_claim high_pri=$highpri_claim"
        return 1
    fi
    log_info "Low-priority NodeClaim: $lowpri_claim ($(nodeclaim_instance_type "$lowpri_claim"))"

    log_info "Scaling $LOWPRI_DEPLOY to 0 — expecting $lowpri_claim to be consolidated..."
    kubectl scale deployment "$LOWPRI_DEPLOY" --replicas=0

    local elapsed=0
    while [ $elapsed -lt $TIMEOUT_CONSOLIDATION ]; do
        local count
        count=$(count_ready_nodeclaims)
        if [ "$count" -eq 1 ]; then
            local remaining
            remaining=$(list_blueprint_nodeclaims | head -1)
            if [ "$remaining" = "$highpri_claim" ]; then
                log_test "PASSED: low-pri host $lowpri_claim consolidated; high-pri host $highpri_claim preserved"
                return 0
            else
                log_error "FAILED: wrong node was consolidated"
                log_error "  expected surviving high-pri: $highpri_claim"
                log_error "  actual surviving:            $remaining"
                return 1
            fi
        fi
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
        echo -n "."
    done
    echo ""

    log_error "FAILED: low-pri NodeClaim $lowpri_claim not consolidated within ${TIMEOUT_CONSOLIDATION}s"
    kubectl get nodeclaims -l "$NODECLAIM_SELECTOR"
    return 1
}

# Test 4: score-gate / feasibility rejects marginal consolidation.
# Scale 0->5 to provision a NodeClaim, then apply a PodDisruptionBudget with
# minAvailable=100% that prevents any pod from being evicted. Karpenter's
# feasibility check will emit Unconsolidatable/DisruptionBlocked (or
# ConsolidationRejected once the score gate fires) *against this specific
# NodeClaim*. We assert on events scoped by involvedObject.name so activity
# on unrelated NodePools cannot satisfy the check.
test_score_gate_pdb() {
    log_test "=== Test 4: Score gate / feasibility blocks marginal consolidation (PDB) ==="

    log_info "Scaling $BASELINE_DEPLOY to 5 replicas..."
    kubectl scale deployment "$BASELINE_DEPLOY" --replicas=5
    if ! wait_for_nodeclaim_count 1; then
        log_error "FAILED: expected 1 NodeClaim after scale-up"
        return 1
    fi

    local claim
    claim=$(list_blueprint_nodeclaims | head -1)
    log_info "NodeClaim under test: $claim ($(nodeclaim_instance_type "$claim"))"

    log_info "Applying PDB with minAvailable=100% (pods must not be evicted)..."
    kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${BASELINE_DEPLOY}-pdb
spec:
  minAvailable: 100%
  selector:
    matchLabels:
      app: ${BASELINE_DEPLOY}
EOF

    log_info "Waiting 90s for Karpenter to evaluate consolidation on $claim..."
    sleep 90

    # Any of these reasons on THIS specific NodeClaim counts as a valid
    # "consolidation blocked/rejected" outcome. Scoping via involvedObject.name
    # means unrelated NodePool activity cannot make this test pass.
    local matched=0
    for reason in Unconsolidatable ConsolidationRejected DisruptionBlocked; do
        local msgs
        msgs=$(nodeclaim_events_by_reason "$claim" "$reason")
        if [ -n "$msgs" ]; then
            matched=$((matched + 1))
            log_info "$reason on $claim:"
            echo "$msgs" | sed 's/^/  - /'
        fi
    done

    kubectl delete pdb "${BASELINE_DEPLOY}-pdb" --ignore-not-found=true

    if [ "$matched" -eq 0 ]; then
        log_error "FAILED: no consolidation-block events emitted against $claim"
        log_info  "Recent events on $claim:"
        kubectl get events --field-selector "involvedObject.kind=NodeClaim,involvedObject.name=$claim" \
            --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
        return 1
    fi

    local current
    current=$(count_ready_nodeclaims)
    if [ "$current" -eq 0 ]; then
        log_error "FAILED: NodeClaim was removed despite PDB blocking eviction"
        return 1
    fi

    log_test "PASSED: consolidation blocked for $claim ($matched event reason(s) matched)"
    return 0
}

# --- Main --------------------------------------------------------------------

main() {
    local exit_code=0

    check_prerequisites
    apply_nodepool || { log_error "Failed to apply NodePool"; exit 1; }

    reset_state
    test_provisioning_and_empty_consolidation || exit_code=1

    reset_state
    test_replace_transition || exit_code=1

    reset_state
    test_priority_weighted || exit_code=1

    reset_state
    test_score_gate_pdb || exit_code=1

    full_cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
