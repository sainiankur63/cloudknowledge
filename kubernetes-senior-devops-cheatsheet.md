# Kubernetes Cheatsheet — Senior DevOps Interview Prep

---

## 1. Architecture

### Control Plane Components
| Component | Role |
|---|---|
| **kube-apiserver** | Front door for all REST operations; validates & processes requests; only component that talks to etcd directly |
| **etcd** | Distributed key-value store; single source of truth for cluster state; needs quorum (odd number of nodes, e.g. 3/5/7) |
| **kube-scheduler** | Watches for unscheduled Pods, assigns them to Nodes based on resource requests, affinity, taints/tolerations, topology spread |
| **kube-controller-manager** | Runs core controllers: Node, ReplicaSet, Endpoints, Namespace, Job, ServiceAccount, etc. Each watches state via API server and reconciles toward desired state |
| **cloud-controller-manager** | Cloud-provider-specific logic (LB provisioning, node lifecycle, routes) — decouples core K8s from cloud APIs |

### Node (Worker) Components
| Component | Role |
|---|---|
| **kubelet** | Agent on every node; ensures containers described in PodSpecs are running & healthy; talks to container runtime via CRI |
| **kube-proxy** | Maintains network rules on nodes (iptables/IPVS) implementing Service abstraction |
| **Container runtime** | containerd / CRI-O (Docker Engine deprecated as of 1.24 — dockershim removed) |

### Reconciliation Loop (core concept — expect deep-dive questions)
Desired state (etcd) → Controller watches → compares to actual state → API calls to reconcile. Everything in Kubernetes is a **level-triggered control loop**, not event-triggered — important distinction to articulate.

### High Availability Control Plane
- Stacked etcd (etcd on same nodes as control plane) vs external etcd cluster
- Odd-numbered etcd members for quorum: tolerate `(N-1)/2` failures
- API servers behind a load balancer (e.g., HAProxy/NLB), kubelets talk to LB
- `--apiserver-count` for lease-based leader election; controller-manager & scheduler use leader election (`--leader-elect=true`) so only one is active

### Pod Lifecycle
`Pending → Running → Succeeded/Failed`; container states: `Waiting → Running → Terminated`.
Readiness vs Liveness vs Startup probes:
- **Liveness** — restart container if failing
- **Readiness** — remove from Service endpoints if failing (doesn't restart)
- **Startup** — protects slow-starting containers from being killed prematurely by liveness

---

## 2. Networking

### The Four Networking Problems K8s Solves
1. Container-to-container (same Pod) → shared network namespace, localhost
2. Pod-to-Pod → flat network, every Pod gets a unique IP (CNI plugin's job)
3. Pod-to-Service → stable virtual IP, load-balanced via kube-proxy
4. External-to-Service → Ingress / LoadBalancer / NodePort

### CNI (Container Network Interface)
- K8s doesn't implement networking itself — delegates to CNI plugins: **Calico** (BGP/eBPF, network policy support, popular in enterprise), **Cilium** (eBPF-based, strong for observability/security, replacing kube-proxy with eBPF), **Flannel** (simple overlay, VXLAN, no NetworkPolicy support), **AWS VPC CNI** / **Azure CNI** (cloud-native IPAM)
- Fundamental requirement: every Pod IP is routable without NAT within cluster

### Services
| Type | Use case |
|---|---|
| **ClusterIP** (default) | Internal-only stable virtual IP |
| **NodePort** | Exposes on `<NodeIP>:30000-32767`, built on ClusterIP |
| **LoadBalancer** | Cloud provider provisions external LB, built on NodePort |
| **ExternalName** | DNS CNAME redirect, no proxying |
| **Headless (clusterIP: None)** | Direct Pod DNS records — used for StatefulSets, client-side LB |

kube-proxy modes: **iptables** (default, O(n) rule chains), **IPVS** (hash table, better at scale), **eBPF** (Cilium replaces kube-proxy entirely)

### Ingress vs Gateway API
- **Ingress**: L7 HTTP(S) routing rules → needs an Ingress Controller (NGINX, Traefik, AWS ALB Controller, Istio Gateway)
- **Gateway API**: newer, more expressive successor (GatewayClass, Gateway, HTTPRoute) — mention awareness of this as a differentiator in interviews
- TLS termination, path-based/host-based routing, annotations for controller-specific behavior

### NetworkPolicy
- Default: all Pods can talk to all Pods (no isolation)
- NetworkPolicy is **namespace-scoped**, **additive** (multiple policies OR together), requires CNI support (Calico/Cilium — NOT Flannel by default)
- `podSelector` + `ingress`/`egress` rules + `policyTypes`
- Default-deny pattern:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
```

### DNS
CoreDNS (in-cluster). Service FQDN: `<service>.<namespace>.svc.cluster.local`. Pod FQDN (headless): `<pod-ip-dashed>.<service>.<namespace>.svc.cluster.local`

### Service Mesh (senior-level talking point)
Istio / Linkerd — sidecar proxy (Envoy) pattern, mTLS between services, traffic shaping (canary, circuit breaking), observability. Trade-off: added latency & operational complexity vs security/observability gains.

---

## 3. Storage & Volumes

### Volume Types
- **emptyDir** — ephemeral, lives with Pod, good for scratch space/sidecar sharing
- **hostPath** — mounts node filesystem — security risk, avoid in multi-tenant clusters
- **PersistentVolume (PV) / PersistentVolumeClaim (PVC)** — decouples storage provisioning from consumption
- **ConfigMap / Secret as volume** — mounted as files, auto-updated (with propagation delay, ~1 min via kubelet sync)
- **CSI (Container Storage Interface)** volumes — standard for cloud/enterprise storage (EBS, Azure Disk, Portworx, Ceph)

### PV/PVC Lifecycle
1. Admin creates **StorageClass** (or dynamic provisioning via CSI driver)
2. User creates **PVC** requesting size/accessMode
3. Controller binds PVC → PV (static) or dynamically provisions one
4. Pod references PVC in `volumes`
5. Reclaim policy on PV: `Retain` (manual cleanup, safest for prod data) / `Delete` / `Recycle` (deprecated)

### Access Modes
| Mode | Meaning |
|---|---|
| RWO (ReadWriteOnce) | Single node read-write |
| ROX (ReadOnlyMany) | Many nodes read-only |
| RWX (ReadWriteMany) | Many nodes read-write (needs NFS/EFS/CephFS-type backend) |
| RWOP (ReadWriteOncePod) | Single **Pod** (newer, stricter than RWO which is per-node) |

### StatefulSets (storage-relevant)
- Stable network identity (`pod-0`, `pod-1`...) + stable storage via `volumeClaimTemplates` — each replica gets its own PVC that persists across rescheduling
- Ordered, graceful deployment/scaling/deletion — critical for databases, Kafka, etcd-like workloads

### StorageClass example
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer   # avoids AZ mismatch
reclaimPolicy: Retain
```
`WaitForFirstConsumer` is a common gotcha question — it delays binding until a Pod is scheduled, avoiding cross-AZ volume/node mismatches.

---

## 4. Access Control — RBAC, Auth, Security

### Authentication vs Authorization vs Admission
Request flow: **Authentication** (who are you — certs, tokens, OIDC) → **Authorization** (RBAC/ABAC/Webhook — are you allowed) → **Admission Controllers** (mutate/validate the request, e.g. PodSecurity, ResourceQuota, OPA/Gatekeeper, ValidatingAdmissionPolicy)

### RBAC Objects
| Object | Scope | Purpose |
|---|---|---|
| **Role** | Namespace | Set of permissions (verbs on resources) within a namespace |
| **ClusterRole** | Cluster-wide | Same, but cluster-scoped OR reusable across namespaces |
| **RoleBinding** | Namespace | Binds a Role (or ClusterRole) to subjects **within a namespace** |
| **ClusterRoleBinding** | Cluster-wide | Binds a ClusterRole to subjects cluster-wide |

Key gotcha (frequently asked): a **ClusterRoleBinding + Role** is invalid — RoleBindings can reference a ClusterRole to grant its permissions *scoped to one namespace* (common pattern for reusable roles like `view`/`edit`/`admin`).

### Example RBAC
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: payments
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: payments
subjects:
- kind: User
  name: jane@bank.com
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount
  name: ci-deployer
  namespace: payments
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### Built-in ClusterRoles
`cluster-admin` (full access), `admin` (full ns access, not cluster resources), `edit` (read/write, no RBAC changes), `view` (read-only)

### ServiceAccounts
- Every Pod runs as a ServiceAccount (default: `default` SA per namespace — should be locked down / disabled `automountServiceAccountToken` unless needed)
- Best practice: one dedicated SA per workload, least privilege, bind narrowly scoped Roles
- Modern auth: **Projected/bound service account tokens** (short-lived, audience-bound, auto-rotated) replaced long-lived static SA token Secrets since 1.24

### Other Security Controls (expect these at senior level, esp. finance sector)
- **Pod Security Admission (PSA)** — replaced deprecated PodSecurityPolicy; levels: `privileged`, `baseline`, `restricted`, enforced via namespace labels
- **NetworkPolicy** — see above, enforce zero-trust between microservices
- **OPA/Gatekeeper or Kyverno** — policy-as-code, custom admission control (e.g., "no `:latest` tags", "must have resource limits", "no root containers")
- **Secrets management** — native Secrets are only base64-encoded (NOT encrypted at rest by default) → enable **encryption at rest** (`EncryptionConfiguration` with KMS provider), or better, use **external secrets** (Vault, AWS Secrets Manager via External Secrets Operator/CSI driver)
- **Image security** — admission-time image signature verification (Cosign/Sigstore), private registries, vulnerability scanning in CI
- **etcd encryption** and **API server audit logging** — critical for regulated environments like banking
- **Node-level**: seccomp, AppArmor/SELinux profiles, read-only root filesystem, `runAsNonRoot`, dropped capabilities

### Security Context example
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

---

## 5. Workloads & Scheduling (likely senior-level territory)

- **Deployment** → ReplicaSet → Pods; rolling updates (`maxSurge`/`maxUnavailable`), rollback via revision history
- **StatefulSet** — ordered, stable identity/storage (databases)
- **DaemonSet** — one Pod per node (log collectors, CNI agents, monitoring)
- **Job/CronJob** — run-to-completion, batch workloads
- **HPA** (Horizontal Pod Autoscaler) — scales replicas on CPU/memory/custom metrics
- **VPA** (Vertical Pod Autoscaler) — adjusts requests/limits
- **Cluster Autoscaler / Karpenter** — scales nodes
- **Affinity/anti-affinity, taints & tolerations, topology spread constraints** — control placement for HA across AZs/racks
- **PodDisruptionBudget (PDB)** — protects availability during voluntary disruptions (node drains, upgrades) — critical to mention for production banking workloads

---

## 6. Troubleshooting Toolkit (common interview scenario questions)

| Symptom | Where to look |
|---|---|
| Pod stuck `Pending` | `kubectl describe pod` → events (insufficient resources, no matching node, PVC unbound, taints) |
| Pod `CrashLoopBackOff` | `kubectl logs <pod> --previous`, check liveness probe config, OOMKilled (`kubectl describe` → check `reason: OOMKilled`) |
| Pod `ImagePullBackOff` | Registry auth (`imagePullSecrets`), wrong tag/typo, network egress to registry |
| Service not reachable | Check `endpoints`/`endpointslices` (label selector mismatch is #1 cause), NetworkPolicy blocking, kube-proxy mode issues |
| Node `NotReady` | kubelet logs, disk pressure, network partition, container runtime health |
| Slow scheduling | Scheduler logs, resource fragmentation, affinity rules too strict, PDB blocking evictions |

Key commands: `kubectl get events --sort-by=.lastTimestamp`, `kubectl top pod/node`, `kubectl exec -it -- sh`, `kubectl debug node/<node> -it --image=busybox`

---

## 7. Quick-Fire Interview Talking Points (JPMorgan / regulated-industry angle)

- **Multi-tenancy**: Namespaces + RBAC + ResourceQuotas + NetworkPolicy + PSA as layered isolation (not a true security boundary like a VM — mention that noisy-neighbor/kernel-sharing risk exists)
- **Compliance/audit**: API server audit logs shipped to SIEM, immutable etcd backups, least-privilege RBAC reviews
- **DR/backup**: etcd snapshotting (`etcdctl snapshot save`), Velero for cluster resource + PV backups
- **GitOps**: ArgoCD/Flux — declarative, auditable deployments (strong fit for change-control-heavy environments like banks)
- **Cost/scale**: Karpenter/Cluster Autoscaler, right-sizing via VPA, spot/on-demand mix
- **Zero downtime**: PDBs + readiness probes + rolling updates + surge capacity planning across AZs
- **Supply chain security**: SBOM, image signing, admission-time policy enforcement — increasingly asked at finance-sector interviews

---

*Tip: for a senior/lead-level interview, be ready to whiteboard the request flow (client → API server → etcd → scheduler → kubelet → CNI → CRI) and to reason about trade-offs (iptables vs IPVS vs eBPF; sidecar mesh vs no mesh; StatefulSet vs operator-managed DB) rather than just recite definitions.*
