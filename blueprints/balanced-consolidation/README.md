# Karpenter Blueprint: Balanced Consolidation Policy

## Purpose

Karpenter's `consolidationPolicy` decides which nodes are candidates for consolidation. The default `WhenEmptyOrUnderutilized` is aggressive — any node that could be removed or replaced to reduce cost is fair game — which produces two behaviors customers commonly hit:

- **Marginal replaces.** A node running just a couple of pods that could technically fit on a same-or-similar-family instance gets replaced. Savings are near zero; several pods get evicted for no real benefit.
- **Consolidation timing pressure.** To contain this, customers reach for scheduled `disruption.budgets` with `nodes: 0` windows during business hours, effectively pausing consolidation until off-hours. That controls the *when* but not the *what* — off-hours consolidation still churns marginal moves.

The `Balanced` policy (Karpenter v1.14+) addresses the *what*: it **scores every consolidation action** and only proceeds when the estimated savings are worth the pod disruption. Because it filters out the marginal actions that made scheduled budgets attractive, teams can be less restrictive with their budget windows once Balanced is in play.

The score is a ratio computed per action:

```
score = savings_fraction / disruption_fraction

  savings_fraction    = savings / nodepool_total_cost
  disruption_fraction = disruption_cost / nodepool_total_disruption_cost
```

An action is approved when `score >= 1/k`. Balanced uses `k = 2`, so the effective **approval threshold is 0.5** — the savings must cover at least half the disruption in fractional terms. Both sides are dimensionless, so the threshold is scale-invariant across cluster sizes. Two levers change per-pod disruption weight in the numerator:

- **Pod priority.** Higher-priority pods count as more disruptive, making their host less consolidation-worthy.
- **`controller.kubernetes.io/pod-deletion-cost` annotation.** Per-pod override on disruption weight.

Balanced still runs the same three consolidation mechanisms as the other policies:

| Mechanism | Balanced behavior |
| --- | --- |
| Empty node consolidation | Empty nodes always clear the threshold (disruption is small, savings dominate). Same behavior as `WhenEmpty`. |
| Multi-node consolidation | The batch's combined savings scores against the batch's combined disruption. Individually-marginal nodes can combine into a passing group. |
| Single-node consolidation | Scored per node. Same-type or near-zero-savings replaces score below 0.5 and are rejected. |

Reference: [Karpenter Balanced consolidation docs](https://karpenter.sh/docs/concepts/disruption/#balanced-consolidation) and the [design RFC](https://github.com/kubernetes-sigs/karpenter/blob/main/designs/balanced-consolidation.md) (see "Why k=2" for the choice of threshold).

## Requirements

- An EKS cluster running Karpenter **v1.14 or later**. Earlier versions do not accept `Balanced` as a `consolidationPolicy` value.
- The reference cluster template in this repo provisions a `default` `EC2NodeClass` and `NodePool`. This blueprint does **not** modify either — it creates its own `balanced-consolidation` NodePool alongside them so this blueprint can be deployed and tested in parallel with others.
- A workload you don't mind scaling up and down a few times. The sample `workload.yaml` in this folder is a `pause`-based inflate deployment.

## Deploy

**Self-managed Karpenter:**

```sh
kubectl apply -f balanced-consolidation.yaml
```

**EKS Auto Mode:**

```sh
kubectl apply -f balanced-consolidation-automode.yaml
```

Both manifests create a **new** `EC2NodeClass` and `NodePool` named `balanced-consolidation`. The Auto Mode variant differs only in the `nodeClassRef` (`eks.amazonaws.com/NodeClass` instead of `karpenter.k8s.aws/EC2NodeClass`) and reuses Auto Mode's built-in `default` NodeClass.

Apply the sample workload — three deployments (baseline, low-priority, high-priority) plus two PriorityClasses:

```sh
kubectl apply -f workload.yaml
```

All deployments start at `replicas: 0` and use `nodeSelector: blueprint=balanced-consolidation`, so they only ever schedule onto this blueprint's own NodePool. Scaling them is how you drive the walkthrough below.

## Walkthrough

The rest of this document is a **progression** on the same workload, comparing `WhenEmptyOrUnderutilized` and `Balanced` and then introducing priority. Each step tells you what to do, what to look for, and what it means.

---

### Step 1 — Baseline: `WhenEmptyOrUnderutilized` on the same workload

Switch the blueprint's NodePool to the traditional policy so you have a clean baseline:

```sh
kubectl patch nodepool balanced-consolidation --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmptyOrUnderutilized"}}}'
```

Scale the baseline `balanced-inflate` deployment up to trigger provisioning, wait for the pods to schedule, and check where they land:

```sh
kubectl scale deployment balanced-inflate --replicas=8
```

The relevant bit of that deployment (pinned to this blueprint's NodePool):

```yaml
spec:
  template:
    spec:
      nodeSelector:
        blueprint: balanced-consolidation
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests: {cpu: "1", memory: "1Gi"}
```

Karpenter provisions a node from the pool (typically a `c*.2xlarge` or similar to absorb 8 CPUs). Now scale down to a size that leaves the node clearly underutilized — say 3 pods — and watch what Karpenter does:

```sh
kubectl scale deployment balanced-inflate --replicas=3
kubectl get nodeclaim -l karpenter.sh/nodepool=balanced-consolidation -w
```

Two things you may see under `WhenEmptyOrUnderutilized`:

1. If 3 pods happen to fit on a smaller replacement, Karpenter **replaces** the node with a cheaper one — 3 pods get evicted and rescheduled. Savings are real but modest; the disruption isn't scored.
2. If no cheaper replacement is feasible, Karpenter emits an `Unconsolidatable` event and the node stays.

Look for the eviction/replacement activity:

```sh
kubectl get events --field-selector reason=DisruptionTerminating --sort-by=.lastTimestamp
kubectl get events --field-selector reason=Unconsolidatable --sort-by=.lastTimestamp
```

You'll see event messages like `Disrupting Node: Underutilized` or `Can't replace with a cheaper node`. Under `WhenEmptyOrUnderutilized`, every feasible replace is attempted — including marginal ones.

---

### Step 2 — Switch to `Balanced`, same workload

Patch the policy without changing the workload:

```sh
kubectl patch nodepool balanced-consolidation --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"Balanced"}}}'
```

Repeat the same scale-down cycle:

```sh
kubectl scale deployment balanced-inflate --replicas=8
# wait for provisioning
kubectl scale deployment balanced-inflate --replicas=3
```

Now watch for **`ConsolidationApproved`** and **`ConsolidationRejected`** events. Balanced emits both, with the score inline:

```sh
kubectl get events --field-selector reason=ConsolidationApproved --sort-by=.lastTimestamp
kubectl get events --field-selector reason=ConsolidationRejected --sort-by=.lastTimestamp
```

The event message looks like:

```
score 0.32 < threshold 0.50 (k: 2, savings 12.5%, disruption 38.7%)
```

For **single-node** consolidation actions, `ConsolidationApproved`/`ConsolidationRejected` fire on the individual NodeClaim, so you can inspect the decision directly on the node object:

```sh
kubectl describe nodeclaim -l karpenter.sh/nodepool=balanced-consolidation
```

For **multi-node** actions, the event fires on the NodePool instead (because the score describes the batch, not any single node):

```sh
kubectl describe nodepool balanced-consolidation
```

**What you should see:** empty nodes still get consolidated (their score clears the threshold easily). Marginal replaces — the same actions that would fire under `WhenEmptyOrUnderutilized` — get scored and, when savings-fraction is less than half the disruption-fraction, rejected. The node stays. Pods aren't evicted for no reason.

Metrics-side observation (the exposed histograms are lazy-initialized, so they appear once at least one scored action has been evaluated):

```sh
kubectl -n kube-system port-forward svc/karpenter 8080:8080 &
curl -s :8080/metrics | grep karpenter_consolidation_score
curl -s :8080/metrics | grep karpenter_consolidation_moves_total
```

`karpenter_consolidation_score` is a histogram bucketed at `{0.1, 0.25, 0.33, 0.5, 1.0, 2.0, 5.0, 10.0}`. `karpenter_consolidation_moves_total` is a counter labeled by `decision` (`approved`/`rejected`), `nodepool`, and `policy`.

---

### Step 3 — Priority-weighted disruption

Now the story escalates. Some of your workloads have become more important — you want their eviction to weigh heavier in consolidation decisions.

Clean up the baseline and switch to the two priority-classed deployments:

```sh
kubectl scale deployment balanced-inflate --replicas=0
kubectl scale deployment balanced-inflate-highpri --replicas=3
kubectl scale deployment balanced-inflate-lowpri  --replicas=3
```

The relevant bits of those two deployments, inline:

```yaml
# balanced-inflate-highpri
spec:
  template:
    spec:
      priorityClassName: balanced-blueprint-high   # value 1000
      nodeSelector: {blueprint: balanced-consolidation}
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources: {requests: {cpu: "1", memory: "1Gi"}}
```

```yaml
# balanced-inflate-lowpri — same shape, priorityClassName: balanced-blueprint-low (value 100)
```

Karpenter provisions capacity and the pods spread across the pool's nodes. Scale one deployment down to create an underutilization opportunity:

```sh
kubectl scale deployment balanced-inflate-lowpri --replicas=1
```

Because Balanced weights per-pod disruption by pod priority, the node hosting **more high-priority pods** carries a larger `disruption_fraction` — its score sits below the threshold and it stays. The node hosting the mostly-low-priority pods carries a smaller `disruption_fraction` — its score clears the threshold and it gets consolidated.

Verify:

```sh
kubectl get pods -l app=balanced-inflate-highpri -o wide
kubectl get pods -l app=balanced-inflate-lowpri  -o wide
kubectl get events --field-selector reason=ConsolidationApproved --sort-by=.lastTimestamp
```

You should see the low-priority host go through `ConsolidationApproved` → `DisruptionTerminating`, while the high-priority host emits `ConsolidationRejected` with a score below 0.50.

## Takeaways

- **Same base behavior.** Balanced still removes empty and clearly-underutilized nodes — you don't lose the base consolidation.
- **Marginal actions blocked.** Balanced adds a scoring gate that rejects marginal single-node replaces, which is where `WhenEmptyOrUnderutilized`'s churn came from.
- **Priority is a first-class signal.** Higher-priority pods make their host less consolidation-worthy, so you can steer consolidation away from critical workloads with the `PriorityClass` you probably already use for scheduling.
- **Budget windows can relax.** If you had scheduled `disruption.budgets` with `nodes: 0` windows to contain churn, Balanced removes much of the reason to. Windows still matter for high-blast-radius operations (drift, expiration), but consolidation-driven churn is now bounded by the score gate.

## Cleanup

```sh
kubectl delete -f workload.yaml
kubectl delete -f balanced-consolidation.yaml       # or -automode.yaml
```

## References

- Karpenter release notes: [v1.14.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.14.0)
- Karpenter disruption docs: [karpenter.sh/docs/concepts/disruption](https://karpenter.sh/docs/concepts/disruption/#balanced-consolidation)
- Balanced consolidation RFC: [designs/balanced-consolidation.md](https://github.com/kubernetes-sigs/karpenter/blob/main/designs/balanced-consolidation.md)
- Karpenter NodePool spec: [karpenter.sh/docs/concepts/nodepools](https://karpenter.sh/docs/concepts/nodepools/)
