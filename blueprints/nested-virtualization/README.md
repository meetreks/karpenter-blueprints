# Karpenter Blueprint: Nested Virtualization on EC2

## Purpose

Some workloads need to run a lightweight virtual machine inside a pod — Kata Containers as an isolation runtime, QEMU-driven CI runners, KVM-based device emulators, or nested KVM in a build sandbox. All of these require the underlying EC2 instance to have **nested virtualization** enabled at launch time. Historically this meant custom launch templates and manual node lifecycle management.

Karpenter [v1.13.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.13.0) (June 2026) added a first-class field on `EC2NodeClass`:

```yaml
spec:
  cpuOptions:
    nestedVirtualization: enabled   # or "disabled"
```

Karpenter forwards this into the instance's `CpuOptions` at launch and additionally filters candidate instance types to only those whose EC2 `ProcessorInfo.SupportedFeatures` reports `nested-virtualization`. Today that filter narrows selection to the `*8i*` families — `c8i`, `m8i`, `r8i` (and their `-flex` variants). This blueprint pins to the non-flex variants for predictable instance sizing, but you can widen the family list on the NodePool if you want flex behavior. If your NodePool requirements don't intersect with any of these families, Karpenter won't schedule the node.

This blueprint provisions a NodePool that only launches nested-virt-capable instances, and includes a demo pod that verifies nested virt is actually accessible from inside the pod (via `/proc/cpuinfo` and `/dev/kvm`).

## Requirements

- An EKS cluster running **self-managed Karpenter v1.13 or later**. Earlier versions do not expose `cpuOptions` on the EC2NodeClass CRD.
- **This blueprint does not apply to EKS Auto Mode.** Auto Mode's `NodeClass` (`eks.amazonaws.com/v1`) does not expose a `cpuOptions` field. If you want nested virtualization on Auto Mode, you'd need to run OSS Karpenter alongside — a supported but atypical configuration. This blueprint targets standard self-managed Karpenter clusters.
- An `EC2NodeClass` reference wiring (subnets, security groups, node role) — the cluster template in this repo produces one. The blueprint creates a **new** dedicated `nested-virt` EC2NodeClass rather than mutating `default`.
- Cluster in a region where the `*8i*` families are offered. As of writing, this includes us-east-1, us-west-2, eu-west-1, ap-southeast-1, ap-northeast-1 (verified in the [feature PR](https://github.com/aws/karpenter-provider-aws/pull/9043)).

## Deploy

Apply the NodePool and EC2NodeClass:

```sh
kubectl apply -f nested-virtualization.yaml
```

Verify both are Ready:

```sh
kubectl get ec2nodeclass nested-virt
kubectl get nodepool nested-virt
```

Deploy the verification workload — a privileged pod that inspects the host CPU and checks for `/dev/kvm`. Here's the relevant slice inline:

```yaml
spec:
  nodeSelector:
    blueprint: nested-virtualization
  containers:
    - name: verify
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      securityContext:
        privileged: true      # required to see /dev/kvm
      command: ["/bin/sh", "-c"]
      args:
        - |
          grep -om1 'vmx\|svm' /proc/cpuinfo || exit 1
          ls -l /dev/kvm || exit 1
          sleep infinity
```

`privileged: true` is intentional for the demonstration — real nested-virt workloads (Kata Containers, KVM CI runners) would use a proper RuntimeClass plus a KVM device plugin instead of a privileged pod.

Apply it:

```sh
kubectl apply -f workload.yaml
```

Karpenter provisions an `*8i*` instance to accommodate the workload (typically `m8i.large` under the requirements above). Watch the provisioning through the NodeClaim:

```sh
kubectl get nodeclaim -l karpenter.sh/nodepool=nested-virt -w

# When Ready, look at the details — instance type, capacity type,
# and the launch events (Nominated/Launched/Registered/Ready):
kubectl describe nodeclaim -l karpenter.sh/nodepool=nested-virt
```

## Verify nested virtualization is functional

Two independent checks — one from the AWS control plane (informational), one from inside the pod (definitive).

**Data-plane check (definitive proof):**

```sh
POD=$(kubectl get pod -l app=nested-virt-demo -o jsonpath='{.items[0].metadata.name}')

# 1. Host CPU exposes virtualization extensions (Intel: vmx, AMD: svm).
kubectl exec "$POD" -- grep -o 'vmx\|svm' /proc/cpuinfo | sort -u
# Expected: vmx      (all *8i* families are Intel Xeon 6)

# 2. /dev/kvm exists and is accessible.
kubectl exec "$POD" -- ls -l /dev/kvm
# Expected: crw-rw----+ 1 root kvm ... /dev/kvm
```

If both come back positive, nested virt is fully functional on the pod's host node.

**Control-plane check (informational):**

```sh
INSTANCE_ID=$(kubectl get nodes -l karpenter.sh/nodepool=nested-virt \
  -o jsonpath='{.items[0].spec.providerID}' | awk -F/ '{print $NF}')

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Type:InstanceType,CpuOptions:CpuOptions}' \
  --output json
```

Note that `CpuOptions.NestedVirtualization` in the response can appear as `null`/`None` on `*8i*` families even when nested virt is functional. These families natively pass CPU virt extensions through the Nitro System — the field only echoes back in the API response when explicitly set at launch time in a way that differs from the family's default state. Karpenter's role is to *pick a family that supports nested virt* (via the `NestedVirtualizationFilter`) and forward the CpuOption in the launch template; the operational proof lives in the pod, not in the metadata.

**Negative case:** if you edit the NodePool requirements to include a family that doesn't support nested virtualization (say `m7i`), Karpenter will reject that instance type. You'll see:

```sh
kubectl get events --field-selector reason=FailedScheduling
```

with a message that no suitable instance type could be found — this is the `NestedVirtualizationFilter` doing its job.

## Cost

Rough on-demand pricing in `us-west-2` at the time of writing:

| Instance | vCPU | Mem | ~$/hr |
| --- | --- | --- | --- |
| `m8i.large` | 2 | 8 Gi | $0.10 |
| `m8i.xlarge` | 4 | 16 Gi | $0.20 |
| `c8i.large` | 2 | 4 Gi | $0.09 |
| `r8i.large` | 2 | 16 Gi | $0.13 |

Running the demo pod alone will provision one `m8i.large`. Delete the workload when you're done and Karpenter will consolidate the node.

## Extending: run an actual guest VM

The included workload proves nested virt is *accessible*. To prove it *works end-to-end*, you can boot a real guest VM inside the pod. A minimal QEMU-based demo:

```yaml
containers:
  - name: qemu-guest
    image: qemux/qemu:latest
    securityContext:
      privileged: true
    env:
      - name: BOOT
        value: "alpine"
      - name: RAM_SIZE
        value: "512M"
      - name: CPU_CORES
        value: "1"
```

This is intentionally left as an extension rather than the default demo, because a full guest VM adds image size and boot time and obscures what the blueprint is actually about (Karpenter provisioning the right kind of node). The two host-level checks in `workload.yaml` are sufficient to prove Karpenter's plumbing.

## References

- Karpenter release notes: [v1.13.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.13.0)
- Feature PR: [karpenter-provider-aws#9043](https://github.com/aws/karpenter-provider-aws/pull/9043)
- Karpenter EC2NodeClass docs: [karpenter.sh/docs/concepts/nodeclasses/](https://karpenter.sh/docs/concepts/nodeclasses/)
- EC2 nested virtualization on Intel Xeon 6: [AWS blog announcement](https://aws.amazon.com/ec2/instance-types/)
