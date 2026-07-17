# Karpenter Cheatsheet & Interview Questions — Senior DevOps Prep

---

## 1. What Is Karpenter & Why It Exists

Karpenter is an open-source, **Kubernetes-native node autoscaler** (originated at AWS, now donated to Kubernetes/CNCF sandbox, supports AWS with growing Azure/other provider support). It provisions right-sized compute **just-in-time** in direct response to unschedulable Pods, rather than managing fixed node groups.

### Karpenter vs Cluster Autoscaler (the #1 interview question)
| | Cluster Autoscaler (CA) | Karpenter |
|---|---|---|
| Model | Scales predefined **node groups / ASGs** up/down | Directly provisions/deprovisions individual **EC2 instances** — no node group indirection |
| Instance selection | Fixed instance type per ASG — you pre-define groups per type/size | Dynamically picks best-fit instance type/size/AZ/purchase-option from a flexible set at launch time |
| Scaling speed | Slower — bound by ASG scaling semantics | Faster — talks directly to cloud provider APIs (EC2 Fleet) |
| Bin-packing | Limited — scales whichever ASG matches, not always optimal | Actively considers pod requests to pick the cheapest/best-fit instance |
| Consolidation | Node group scale-down based on utilization thresholds | Continuous **consolidation** — actively replaces/removes underutilized nodes, including replacing with a cheaper instance type |
| Config surface | ASG + CA flags (`--scale-down-*`, `--expander`) | Kubernetes CRDs (`NodePool`, `EC2NodeClass`) — fully declarative, GitOps-friendly |
| Spot handling | Possible but clunkier (separate ASGs per type) | Native, flexible Spot/On-Demand mixing with automatic diversification across instance types to reduce interruption risk |

---

## 2. Core Concepts / CRDs (API changed in v1beta1/v1 — know the naming)

> Note: Karpenter's API evolved — v1alpha5 used `Provisioner` + `AWSNodeTemplate`; **current stable API (v1)** uses `NodePool` + `EC2NodeClass` (`NodeClaim` replaces the old concept of a Machine). Mention this evolution if asked — shows currency.

| Resource | Purpose |
|---|---|
| **NodePool** | Defines *what kind* of nodes Karpenter is allowed to launch — instance requirements, taints, labels, limits, disruption/consolidation policy. Analogous to what a "node group" used to represent, but far more flexible (can express many instance types/families in one pool) |
| **EC2NodeClass** (AWS-specific) | Defines *how* to launch the node — AMI family, subnet/security-group selectors, block device mappings, IAM instance profile, user data |
| **NodeClaim** | Karpenter's internal representation of "I need/have a specific node" — created automatically per launched node; you rarely author these directly |

### Example NodePool
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-category
          operator: In
          values: ["c", "m", "r"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      taints:
        - key: dedicated
          value: gpu-workloads
          effect: NoSchedule
  limits:
    cpu: "1000"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
    expireAfter: 720h            # forced node recycling (720h = 30 days) for AMI/patch hygiene
```

### Example EC2NodeClass
```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: "KarpenterNodeRole"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: my-cluster
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: my-cluster
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
```

---

## 3. How Provisioning Actually Works (be ready to whiteboard)

1. Pod created → scheduler can't find a fit → Pod stays `Pending`
2. Karpenter watches for unschedulable Pods (via scheduler simulation, not just events)
3. Evaluates all `NodePool` constraints, Pod's `nodeSelector`/`affinity`/`tolerations`/resource requests
4. Calls cloud provider (EC2 Fleet API) with a **flexible list** of viable instance types — lets AWS pick cheapest available capacity matching constraints
5. Node joins cluster, kubelet registers, Pod scheduled by kube-scheduler as normal (Karpenter doesn't do the actual pod-to-node binding — that's still kube-scheduler)
6. Karpenter continuously watches for **consolidation opportunities**: empty nodes, underutilized nodes that could be replaced by a cheaper/smaller instance, or workloads that could be repacked onto fewer nodes

### Deprovisioning / Disruption Reasons
- **Empty** — no pods running, node removed after `consolidateAfter`
- **Underutilized / consolidation** — node's workload could fit on a cheaper or fewer instances → replace
- **Expired** — node older than `expireAfter` → forced replacement (patching/AMI hygiene)
- **Drifted** — node's config no longer matches current NodePool/EC2NodeClass spec (e.g., you changed the AMI) → replaced
- **Interruption** — Spot interruption notice (2-min warning) → Karpenter proactively drains/reschedules
- Karpenter respects **PodDisruptionBudgets** and **do-not-disrupt** annotation during voluntary disruption

---

## 4. Key Features to Articulate in Interview

- **Just-in-time provisioning** — no pre-scaled buffer node groups required; can go from Pending Pod to Running in ~30-60s typically (AMI/image pull time dependent)
- **Bin-packing efficiency** — chooses instance type that fits workload tightly rather than a one-size-fits-all node group, reducing waste
- **Spot-friendly by design** — diversifies across many instance types/AZs automatically to minimize simultaneous interruption risk; handles the 2-minute Spot interruption notice gracefully
- **Consolidation** — continuously right-sizes the cluster, unlike CA which mostly only scales down empty nodes
- **`weight` on NodePools** — multiple NodePools can coexist (e.g., general vs GPU vs Spot-preferred); weight determines preference order when several are eligible
- **`limits`** on NodePool — hard caps on total resources (cpu/memory) a NodePool can provision — a cost/blast-radius control
- **Drift detection** — declarative reconciliation extends to node config itself, not just pod scheduling — nodes auto-replaced if NodePool/EC2NodeClass spec changes
- **`do-not-disrupt` annotation** — pin critical pods' nodes from voluntary consolidation/expiration (e.g., a stateful workload mid-operation)

---

## 5. Common Interview / Real-World Gotchas

- Karpenter needs **IAM permissions** scoped tightly (EC2 Fleet, PassRole for node IAM role) — over-broad IAM here is a common security review finding
- **Interruption handling** requires the AWS interruption queue (SQS) + Karpenter's interruption controller enabled — without it, Spot terminations aren't graceful
- Setting `expireAfter` too aggressively in a stateful/long-lived-connection environment can cause unnecessary churn — balance patching hygiene vs stability
- NodePool `requirements` too narrow (e.g., pinning a single instance type) defeats Karpenter's core value — defeats flexible bin-packing and Spot diversification
- Karpenter does **not** replace the kube-scheduler — it's a *provisioner*, scheduling decisions are still native K8s scheduler logic
- Migration from Cluster Autoscaler: usually run both temporarily with **taints to segregate**, cordon/drain CA-managed node groups gradually — a "how would you migrate" scenario question is common
- `consolidateAfter` too low can cause node flapping under bursty load — cost savings vs stability trade-off

---

## 6. CLI / Operational Cheat Sheet

```bash
# Check Karpenter controller status
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# View NodePools / NodeClasses
kubectl get nodepools
kubectl get ec2nodeclasses

# View NodeClaims (Karpenter-managed nodes)
kubectl get nodeclaims
kubectl describe nodeclaim <name>

# Watch Karpenter's decisions
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f

# Force expire/replace a node manually
kubectl delete nodeclaim <name>

# Check why a pod isn't scheduling (works with Karpenter too)
kubectl describe pod <pod> | grep -A5 Events
```

---

## 7. Interview Questions

### Conceptual / Fundamentals
1. What problem does Karpenter solve compared to the Kubernetes Cluster Autoscaler?
2. Walk me through what happens, step by step, from a Pod going `Pending` to a new node being ready to run it, using Karpenter.
3. What's the difference between a `NodePool` and an `EC2NodeClass`?
4. Does Karpenter replace kube-scheduler? Why or why not?
5. What is "consolidation" in Karpenter, and what disruption reasons trigger it?
6. How does Karpenter decide which EC2 instance type to launch for a given pending Pod?
7. What is a `NodeClaim`, and do you typically create these yourself?

### Practical / Scenario-based
8. Your Spot instances keep getting interrupted and workloads aren't draining gracefully — what would you check? *(→ interruption queue/SQS wiring, interruption controller, whether workloads tolerate spot/have PDBs)*
9. A workload keeps getting evicted and rescheduled every few minutes, wasting compute — what Karpenter setting is likely misconfigured? *(→ `consolidateAfter` too aggressive, or missing `do-not-disrupt`)*
10. You changed your EC2NodeClass AMI and want existing nodes to roll over safely — what happens automatically, and how do you control the pace? *(→ drift detection triggers replacement; use PDBs/`do-not-disrupt` to control blast radius, consider node budgets)*
11. How would you migrate a production cluster from Cluster Autoscaler + fixed node groups to Karpenter with minimal disruption?
12. You need a dedicated pool of GPU nodes that regular workloads should never land on — how do you express that? *(→ taints on NodePool + matching tolerations on GPU workloads)*
13. Finance/compliance wants a hard ceiling on how much compute a given team's workloads can autoscale to — how do you enforce that in Karpenter? *(→ `limits` on NodePool, plus ResourceQuota at namespace level)*
14. How do you prevent a critical stateful pod (e.g., mid-write to a volume) from being disrupted during a routine consolidation event? *(→ `karpenter.sh/do-not-disrupt: "true"` annotation, PDBs)*

### Design / Trade-off Discussion (senior-level)
15. When might you still prefer Cluster Autoscaler / fixed node groups over Karpenter (e.g., strict compliance-approved AMI/instance allowlists, simpler mental model, existing tooling)?
16. How do you balance cost optimization (aggressive consolidation, Spot usage) against workload stability in a latency-sensitive, regulated financial workload?
17. How would you set up separate NodePools for different workload classes (e.g., general microservices vs. batch/Spot-tolerant vs. GPU) and what would govern their priority when a pod could fit multiple pools? *(→ `weight` field, taints/tolerations, requirements)*
18. What's your strategy for patching/AMI rotation across the fleet using Karpenter's `expireAfter` and drift detection, while staying within change-control windows typical of a bank?

---

*Karpenter questions often connect back to cost governance and change-control — for a JPMorgan-style interview, be ready to talk about how autoscaling decisions get audited/approved and how you'd cap blast radius (limits, PDBs, do-not-disrupt) rather than just describing the happy path.*
