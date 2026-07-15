# Karpenter Blueprint: Balanced Consolidation Policy

## Purpose

Karpenter's `consolidationPolicy` decides which nodes are candidates for consolidation. The default `WhenEmptyOrUnderutilized` policy is aggressive — any node that could be removed or replaced to reduce cost is fair game — which can produce churn: marginal consolidations where the saved dollars are small relative to the number of pods disrupted, and, in some workload shapes, oscillation as pods reschedule onto a node that then becomes underutilized itself.

The `Balanced` policy (introduced in Karpenter v1.14) addresses this by **scoring** every consolidation action instead of only checking feasibility. It considers the same set of nodes as `WhenEmptyOrUnderutilized`, but takes the action only when the estimated cost savings are worth the disruption to the pods that would be evicted.

The score is a ratio:

```
score = savings_fraction / disruption_fraction
```

where `savings_fraction` is the candidate node's cost as a share of the NodePool's total cost, and `disruption_fraction` is the disruption weight of the pods on that node as a share of the NodePool's total pod disruption weight. Karpenter approves an action only when the score clears its threshold. Empty nodes have effectively zero disruption weight, so they always clear — meaning `Balanced` still removes empty nodes just like `WhenEmpty` would.

By default every pod contributes equal disruption weight, so the disruption term reduces to a pod count. Two levers change that per-pod weight:

- **Pod priority** — higher-priority pods count as more disruptive, making their host node less likely to be consolidated.
- **`controller.kubernetes.io/pod-deletion-cost` annotation** — user-supplied override on per-pod disruption weight (positive values increase weight, negative decrease).

Balanced runs the same three consolidation mechanisms as the other policies:

| Mechanism | Balanced behavior |
| --- | --- |
| Empty Node Consolidation | Empty nodes score with disruption ≈ 0, always clear the threshold. Same behavior as `WhenEmpty`. |
| Multi-Node Consolidation | The batch's combined savings is scored against the batch's combined disruption. Individually-marginal nodes can still combine into a passing group. |
| Single-Node Consolidation | Scored per node. A same-type or near-zero-savings replacement scores ≈ 0 and is rejected. This is what closes the consolidation loops sometimes observed under `WhenEmptyOrUnderutilized`. |

Pick `Balanced` when you want most of the cost savings of `WhenEmptyOrUnderutilized` but not the churn from marginal consolidations — especially in clusters with many small workloads, priority-classed workloads, or where you've seen "node deleted, replacement provisioned, same type, no savings" loops.

For the reference behavior and full documentation, see the Karpenter [Balanced consolidation docs](https://karpenter.sh/docs/concepts/disruption/#balanced-consolidation) and the [NodePool disruption spec](https://karpenter.sh/docs/concepts/nodepools/).

## Requirements

- An EKS cluster running Karpenter **v1.14 or later**. Earlier versions do not accept `Balanced` as a `consolidationPolicy` value and will reject the NodePool.
- An `EC2NodeClass` named `default` (self-managed Karpenter) or a Node Class named `default` (EKS Auto Mode). The cluster template in this repo creates one.
- Ability to deploy the sample workload (`workload.yaml`) and scale it. No special IAM permissions beyond a standard Karpenter install.
- (Optional, for the observability section) `kubectl port-forward` access to `svc/karpenter` in `kube-system` to read Prometheus metrics on `:8080`.

## Deploy

**Self-managed Karpenter:**

```sh
kubectl apply -f balanced-consolidation.yaml
```

**EKS Auto Mode:**

```sh
kubectl apply -f balanced-consolidation-automode.yaml
```

Both manifests replace or create a NodePool named `default` with `consolidationPolicy: Balanced` and a 30-second `consolidateAfter`. The Auto Mode variant differs only in the `nodeClassRef` (`eks.amazonaws.com/NodeClass` instead of `karpenter.k8s.aws/EC2NodeClass`) and skips the requirements block since Auto Mode's built-in NodeClass covers instance selection.

Verify the NodePool is `Ready`:

```sh
kubectl get nodepool default
kubectl get nodepool default -o jsonpath='{.spec.disruption.consolidationPolicy}{"\n"}'
```

Then apply the sample workload — an `inflate` deployment plus two `PriorityClass` resources so you can demonstrate the priority-weighted disruption behavior:

```sh
kubectl apply -f workload.yaml
```

### Scenario A — Empty node consolidation (baseline)

Scale up, then scale to zero:

```sh
kubectl scale deployment inflate --replicas=5
# wait for Karpenter to provision a node and pods to be Running
kubectl scale deployment inflate --replicas=0
```

You should observe the Karpenter-provisioned node get consolidated within a minute of `consolidateAfter` elapsing. Because the node is empty, its disruption is ≈ 0, so `Balanced` behaves identically to `WhenEmpty` here.

### Scenario B — Marginal single-node consolidation (rejected)

Scale to a size that produces a node running only a couple of pods where the only feasible replacement is the same or near-identical instance type. Without Balanced, `WhenEmptyOrUnderutilized` would attempt a same-type replacement, produce ≈ 0 net savings, and re-attempt on the next reconcile — a churn loop. Balanced scores this action, finds savings ≈ 0 relative to non-zero disruption, and **rejects** it. The node stays put.

```sh
kubectl scale deployment inflate --replicas=2
```

Watch decisions:

```sh
kubectl get events -n default --field-selector reason=ConsolidationApproved
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i consolidat
```

### Scenario C — Priority-weighted disruption

Deploy two workloads at different priorities on two different nodes. Balanced weights the high-priority pod's disruption higher, making its host node less consolidation-worthy than the low-priority node.

```sh
kubectl scale deployment inflate --replicas=0
kubectl apply -f workload.yaml   # includes high-pri and low-pri variants
```

The `workload.yaml` in this folder defines:

- `inflate-lowpri` — 3 replicas at priority `karpenter-blueprint-low` (value 100)
- `inflate-highpri` — 3 replicas at priority `karpenter-blueprint-high` (value 1000)

Both fit on a single Karpenter-provisioned node initially; scale up so they end up on separate nodes, then scale down so one becomes a consolidation candidate. Balanced should prefer consolidating the `inflate-lowpri` node.

## Results

There are three signals to watch: **metrics**, **events**, and **debug logs**. Which of them fire depends on which consolidation path Karpenter takes.

### Two consolidation paths — one scored, one not

Balanced runs alongside the classic **empty-node fast path**. When a node has no pods (or only pods that are cheap to move — like daemonsets), Karpenter deletes it directly without scoring. When a node has running workload pods and consolidating it requires either evicting them or launching a smaller replacement, Balanced runs the scorer.

You'll observe them differently:

| Path | When it fires | Event | Metric |
| --- | --- | --- | --- |
| Empty-node delete | Node has no workload pods, or all pods can move to existing free capacity | `DisruptionTerminating` with message `Disrupting Node: Empty` | `karpenter_voluntary_disruption_decisions_total{consolidation_type="empty",decision="delete",reason="empty"}` |
| Scored consolidation | Node has workload pods that need to be evicted or replaced, and a cheaper replacement is feasible | `ConsolidationApproved` (approved) or `Unconsolidatable` (rejected) | `karpenter_consolidation_score`, `karpenter_consolidation_moves_total` (both labeled by `decision`, `nodepool`, `policy`) |

The `karpenter_consolidation_score` and `karpenter_consolidation_moves_total` metrics are lazy-initialized. They only appear in `/metrics` **after the scorer has actually run at least once**, which requires a scenario where a scored consolidation action is at least evaluated — not just a scale-up-then-down that resolves via the empty-node fast path.

### What you should see for each scenario

**Scenario A (empty node)** — expect:

```sh
$ kubectl get events --sort-by='.lastTimestamp' | grep -i disrupting
Normal  DisruptionTerminating  node/ip-...  Disrupting Node: Empty
Normal  DisruptionTerminating  nodeclaim/... Disrupting NodeClaim: Empty
```

```sh
$ curl -s :8080/metrics | grep 'consolidation_type="empty"'
karpenter_voluntary_disruption_decisions_total{consolidation_type="empty",decision="delete",reason="empty"} 1
```

The score metrics stay absent because empty-node consolidation doesn't score.

**Scenario B (marginal / unconsolidatable)** — with a PodDisruptionBudget blocking evictions or a workload shape where no cheaper instance fits, Karpenter's feasibility check will reject before the scorer runs. Expect:

```sh
$ kubectl get events --field-selector reason=Unconsolidatable
Normal  Unconsolidatable  nodeclaim/...  Can't replace with a cheaper node
```

This event tells you Karpenter tried to find a consolidation option and couldn't — the scoring never runs.

**Scenario C (priority-weighted)** — when a feasible scored consolidation exists, expect a `ConsolidationApproved` event on the chosen node/NodeClaim, with the score and percentages in its message. In parallel, `karpenter_consolidation_score` and `karpenter_consolidation_moves_total` will appear on `/metrics`, and enabling `LOG_LEVEL=debug` on the controller will surface per-decision scoring detail in the logs.

Enable debug logs by patching the deployment:

```sh
kubectl set env deploy/karpenter -n kube-system LOG_LEVEL=debug
```

Then follow along:

```sh
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f | grep -iE "consolidat|score"
```

### Sizing your test cluster

To reliably elicit the scorer, your cluster needs enough diverse compute for Karpenter to have both an "evict and move pods" option **and** a feasible "replace with smaller/cheaper instance" option. A tiny test cluster where every workload fits on the system nodes will mostly exercise the empty-node fast path — you'll see `Balanced` accept those actions but you won't see the scoring signals fire.

### Takeaway

- Balanced still removes empty and clearly-under-utilized nodes — you don't lose the base consolidation behavior.
- Balanced adds a scoring gate on non-empty consolidations that would otherwise churn the cluster for marginal savings.
- The `karpenter_consolidation_score` / `karpenter_consolidation_moves_total` metrics and `ConsolidationApproved` events give you the *"why"* behind each approved or rejected action.
