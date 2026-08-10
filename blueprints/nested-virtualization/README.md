# Karpenter Blueprint: Nested Virtualization on EC2

## Purpose

Some workloads need to run a lightweight virtual machine inside a pod: Kata Containers as an isolation runtime for agent tool sandboxes, KVM-based CI runners that build test images, KubeVirt to host legacy VMs on Kubernetes, or nested KVM in a security-scanning environment. All of these require the underlying EC2 instance to have **nested virtualization** enabled at launch time. Historically this meant custom launch templates and manual node lifecycle management on `.metal` sizes.

Karpenter [v1.13.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.13.0) (June 2026) added a first-class field on `EC2NodeClass`:

```yaml
spec:
  cpuOptions:
    nestedVirtualization: enabled   # or "disabled"
```

Karpenter forwards this into the instance's `CpuOptions` at launch and additionally filters candidate instance types to only those whose EC2 `ProcessorInfo.SupportedFeatures` reports `nested-virtualization`. See the [AWS EC2 nested virtualization docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html) for the currently supported set, a mix of `*7i` and `*8i` families including `c7i-flex`, `m8i-flex`, `x8i`, `i7i` and more. The NodePool in this blueprint mirrors that list. Update it if AWS adds more families.

The blueprint has two parts:

1. **The Karpenter plumbing**: a `nested-virt` `EC2NodeClass` + `NodePool` that Karpenter uses to provision nested-virt-capable instances on demand.
2. **A real-workload demo**: a small Python-exec sandbox that runs each POSTed script inside its own MicroVM (its own kernel, filesystem and network namespace). This is the canonical agent-tool-sandbox pattern, and the demo proves the plumbing works end-to-end.

We use [Kata Containers](https://katacontainers.io/) as the MicroVM runtime for the demo. [KubeVirt](https://kubevirt.io/) and [Confidential Containers](https://confidentialcontainers.org/) are equivalent choices on the same nested-virt substrate. Kata is used here mainly because it has the shortest install path for a blueprint demo, with no strong preference over the alternatives.

## When to use this blueprint (and when not to)

MicroVM-based sandboxing on AWS gives you three orchestration options. Pick based on where the workload already lives:

| Option | Manages the Firecracker/QEMU fleet | Best for |
|---|---|---|
| **[AWS Lambda MicroVMs](https://aws.amazon.com/lambda/lambda-microvms/)** (GA June 2026) | AWS | Isolated code execution for AI agents / multi-tenant apps as an AWS-native primitive. 8 h sessions, memory + disk state preserved across suspend/resume, HTTPS/gRPC/WebSocket URLs, container image built from a Dockerfile, no infrastructure to operate. **Reach for this first for the AI-agent-tool-sandbox use case unless you have a specific reason not to.** |
| **Kata on Karpenter** (this blueprint) | You | You already run everything on EKS and want in-cluster isolation, VPC-local network paths without a NAT hop, full control of the AMI/kernel/tooling, or a compute contract with no AWS-service dependency. |
| **AWS Fargate** | AWS | You want managed Firecracker-backed containers but don't need the session/state model of Lambda MicroVMs. |

If you're greenfielding an agent that runs untrusted code, look at Lambda MicroVMs before you build this out. If your platform team is already running EKS and this is one more workload class alongside your existing services, this blueprint is a clean fit.

## Requirements

- An EKS cluster running **self-managed Karpenter v1.13 or later**. Earlier versions do not expose `cpuOptions` on the EC2NodeClass CRD.
- **This blueprint is not supported on EKS Auto Mode.** Auto Mode's `NodeClass` (`eks.amazonaws.com/v1`) does not expose a `cpuOptions` field. If you want nested virtualization on Auto Mode, you'd need to run OSS Karpenter alongside, a supported but atypical configuration.
- `helm` v3.
- Cluster in a region where at least one of the supported nested-virt families is available. Check the AWS EC2 nested virtualization docs (linked above) for current regional coverage.

## Deploy

### 1. The Karpenter NodePool + EC2NodeClass

Substitute your cluster's IAM node role name and cluster name (they're used for subnet + security-group discovery), then apply:

```sh
sed -e "s|<<CLUSTER_NAME>>|$CLUSTER_NAME|g" \
    -e "s|<<KARPENTER_NODE_IAM_ROLE_NAME>>|$KARPENTER_NODE_IAM_ROLE_NAME|g" \
    nested-virtualization.yaml | kubectl apply -f -
```

Verify both are `Ready`:

```sh
kubectl get ec2nodeclass nested-virt
kubectl get nodepool nested-virt
```

The pool reports `0` nodes because nothing has been scheduled onto it yet. Nodes are provisioned on demand when the first pod that matches lands in the scheduler.

Three things worth noticing when you look at `nested-virtualization.yaml`:

- **The `cpuOptions` block does two jobs at once.** It sets `NestedVirtualization=enabled` on the launched instance's `CpuOptions` *and* it tells Karpenter's `NestedVirtualizationFilter` to reject any candidate instance type that doesn't support the feature. One field controls both admission and the runtime bit.
- **The `requirements` list mirrors the [AWS-supported families](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html) explicitly.** Karpenter's filter would narrow candidates for us regardless, but listing the families keeps the intent clear and makes it easy to spot when AWS's list drifts.
- **The `startupTaints` entry pairs with the Kata install in step 2.** Fresh nodes come up tainted so Kata workloads can't land before the runtime is installed. kata-deploy removes the taint once the install completes.

### 2. Kata Containers via the upstream Helm chart

Kata v4.0.0 (July 2026) is the recommended version and ships as an OCI-registry Helm chart. Install into `kube-system`:

```sh
KATA_VERSION=4.0.0
helm install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version "$KATA_VERSION" \
  -n kube-system \
  -f - <<'EOF'
nodeSelector:
  katacontainers.io/kata-runtime: "true"
tolerations:
  - key: katacontainers.io/kata-runtime
    operator: Exists
    effect: NoSchedule
startupTaints:
  - "katacontainers.io/kata-runtime:NoSchedule"
EOF
```

The three values work together with the NodePool in `nested-virtualization.yaml`:

- `nodeSelector` scopes the DaemonSet to nodes labeled `katacontainers.io/kata-runtime: "true"`, which is exactly the label this blueprint's NodePool applies to the nodes it provisions. Without it, the chart's default installs Kata's containerd drop-in on **every** node in the cluster, including nodes that have nothing to do with this blueprint.
- The NodePool provisions each node with a **startup taint** of the same key, which keeps workloads off the node until Kata is actually installed. This closes a race: without it, a pod requesting a Kata RuntimeClass can be scheduled onto a fresh node before the runtime binaries exist, and it fails to start until the install catches up.
- `tolerations` lets the kata-deploy pod itself land on the tainted node, and `startupTaints` tells kata-deploy to remove the taint as its final install step, at which point the scheduler admits the waiting workloads.

This creates:

- A `kata-deploy` `DaemonSet`, scoped to nested-virt nodes, that installs the Kata binaries + a drop-in containerd config
- A set of `RuntimeClass` resources: `kata-qemu-runtime-rs`, `kata-fc`, `kata-clh`, and TDX/SNP/confidential variants

You won't see the DaemonSet pod land on nested-virt nodes yet, none exist. It picks them up automatically once Karpenter provisions them below.

### 3. The two verification workloads

Now that the NodePool and the Kata runtime are both in place, we need to check the two layers actually work end-to-end. This section deploys two small pods, one that inspects the underlying node for the nested-virt substrate (Karpenter side), and one that boots inside a Kata MicroVM (Kata side), so you can see each layer doing its job.

**Host-level check**: a privileged pod that inspects `/dev/kvm` on the underlying node. This checks the Karpenter plumbing only. It doesn't need Kata.

```sh
kubectl apply -f workload.yaml
```

Karpenter provisions the cheapest nested-virt-capable instance that fits (`c7i-flex.large` is a common pick under the requirements shipped here). Once the pod is Running, check the logs:

```sh
kubectl logs deploy/nested-virt-demo
```

You should see something like:

```
=== CPU virtualization extensions in /proc/cpuinfo ===
vmx
=== /dev/kvm ===
crw-rw-rw-. 1 root 36 10, 232 Jul 22 20:08 /dev/kvm
PASS: nested virtualization is accessible from this pod.
```

**MicroVM check**: a pod that runs *inside* a Kata MicroVM via the `kata-qemu-runtime-rs` RuntimeClass. This proves Kata is functional on the node, not just that the CPU flag is there.

```sh
kubectl apply -f sandbox-workload.yaml
kubectl logs kata-verify
```

Expected output:

```
=== Guest kernel (what this container sees) ===
Linux kata-verify 6.18.35 #1 SMP Sat Jul 18 15:27:25 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
  Note the kernel differs from the host — Kata's minimal guest
  kernel, not the AL2023 host kernel. That's the MicroVM boundary.

PASS: this container is running inside a Kata MicroVM (QEMU VMM under runtime-rs).
```

The interesting line is the kernel version: the guest reports `6.18.35` where the host runs the AL2023 `6.12.x` kernel. That's the MicroVM boundary.

## The agent tool sandbox

`sandbox.yaml` deploys a tiny HTTP service (Python's stdlib `http.server` for zero image bloat) that accepts `POST /exec {"code": "..."}` and returns the stdout / stderr / exit code of running that Python code. **The service runs inside a Kata MicroVM** (`runtimeClassName: kata-qemu-runtime-rs`), so any code you `POST` to it executes in its own kernel and filesystem.

> ⚠️ **Do not expose this sandbox to the public internet.** The `Service` in `sandbox.yaml` is `ClusterIP` (in-cluster only) and there is no authentication on `POST /exec`, it will run whatever Python you give it. That's fine for a blueprint demo, but for real use put an authenticating proxy in front, keep it internal, or wrap the exec API in your agent framework's tool-call auth layer.

Deploy it:

```sh
kubectl apply -f sandbox.yaml
kubectl wait --for=condition=available deploy/sandbox --timeout=180s
```

Then hit it from a client pod outside Kata:

```sh
kubectl run sandbox-client --rm -i --restart=Never \
  --image=curlimages/curl:latest -- sh -c '
    echo "== hello ==";           curl -s -X POST http://sandbox/exec -H "Content-Type: application/json" -d "{\"code\":\"print(\\\"hello from inside a MicroVM\\\")\"}"
    echo
    echo "== kernel identity =="; curl -s -X POST http://sandbox/exec -H "Content-Type: application/json" -d "{\"code\":\"import os; print(os.uname().release)\"}"
    echo
    echo "== destructive rm =="; curl -s -X POST http://sandbox/exec -H "Content-Type: application/json" -d "{\"code\":\"import subprocess; r=subprocess.run([\\\"rm\\\",\\\"-rf\\\",\\\"/tmp/x\\\"], capture_output=True, text=True); print(\\\"rc=\\\", r.returncode)\"}"
  '
```

Sample response:

```json
{"stdout": "hello from inside a MicroVM\n", "stderr": "", "exit_code": 0, "hostname": "sandbox-...", "kernel": "6.18.35"}
{"stdout": "6.18.35\n", "stderr": "", "exit_code": 0, "hostname": "sandbox-...", "kernel": "6.18.35"}
{"stdout": "rc= 0\n", "stderr": "", "exit_code": 0, "hostname": "sandbox-...", "kernel": "6.18.35"}
```

Two things worth noting:

1. **`kernel: 6.18.35`** in the response payload is what the exec'd Python sees. The host node is AL2023 with a 6.12.x kernel. Different kernels = different VMs. Different VMs = hard isolation.
2. **`rm -rf /tmp/x`** succeeded (rc=0) inside the MicroVM. The host node's `/tmp` is untouched. Try a genuinely destructive pattern and it still won't reach the host. The MicroVM filesystem is ephemeral to the pod.

Every replica of the `sandbox` Deployment gets its own MicroVM, so scaling replicas gives you a per-tool-call isolation model out of the box.

## Extending

A few directions to take the blueprint further, from swapping the underlying VMM to switching the workload type entirely:

- **Firecracker VMM.** The upstream Helm chart wires `kata-fc` to the `devmapper` snapshotter for a small-image-fast-boot pattern (Firecracker's sweet spot: ~125 ms boot, ~5 MB VMM overhead). AL2023 doesn't have a devmapper thin-pool by default, so `kata-fc` fails to launch pods out of the box. To use it: prepare a devmapper thin-pool on the node (typically via a node bootstrap script or a Bottlerocket variant) and register it with containerd. See the [Kata devmapper snapshotter guide](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-virtio-fs-with-nydus.md) for the setup.
- **Bottlerocket Kata variant.** Bottlerocket ships a `kata`-flavored variant with Kata pre-installed on the AMI, so you skip the DaemonSet install step entirely. Point the `EC2NodeClass.amiSelectorTerms` at the variant's SSM parameter and drop `kata-deploy`.
- **KubeVirt for legacy VMs.** KubeVirt uses the same nested-virt substrate to run full traditional VMs (Windows, unusual kernels, HPC images) as pods. The same NodePool works, just swap the sample workload for a `VirtualMachineInstance` CR.
- **Confidential Containers.** The chart also creates `kata-qemu-snp` and `kata-qemu-tdx` RuntimeClasses. On instance families that expose SEV-SNP or Intel TDX, these give you attested-encrypted memory on top of the MicroVM boundary. Not applicable on the families this NodePool selects today, but useful to know it's the same install path.
- **Negative case.** If you edit the NodePool requirements to include a family without nested-virt support (e.g. `m6i`), Karpenter's `NestedVirtualizationFilter` rejects it and the pod stays `Pending`. Check `kubectl get events --field-selector reason=FailedScheduling`. The message will tell you no suitable instance type could be found.

## Cleanup

```sh
kubectl delete -f sandbox.yaml
kubectl delete -f sandbox-workload.yaml
kubectl delete -f workload.yaml
helm uninstall kata-deploy -n kube-system
kubectl delete -f nested-virtualization.yaml
```

Karpenter will drain and reclaim the nested-virt nodes once nothing tolerates the pool's requirements.

## References

- Karpenter release notes: [v1.13.0](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.13.0) and feature PR [karpenter-provider-aws#9043](https://github.com/aws/karpenter-provider-aws/pull/9043)
- Kata Containers v4.0.0 install guide: [kata-containers.github.io/kata-containers/installation](https://kata-containers.github.io/kata-containers/installation/)
- AWS Lambda MicroVMs launch post: [Run isolated sandboxes with full lifecycle control](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/)
- AWS Compute Blog: [Secure code execution for AI agents with AWS Lambda MicroVMs](https://aws.amazon.com/blogs/compute/secure-code-execution-for-ai-agents-with-aws-lambda-microvms/)
