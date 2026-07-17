# ArgoCD Cheatsheet & Interview Questions — Senior DevOps Prep

---

## 1. What Is ArgoCD & Core GitOps Concepts

ArgoCD is a **declarative, GitOps continuous delivery** tool for Kubernetes. It continuously watches a Git repo (source of truth) and reconciles the live cluster state to match it — the same control-loop philosophy as Kubernetes itself, applied to deployments.

### GitOps Principles (expect a "what is GitOps" question)
1. **Declarative** — desired state described declaratively (YAML/Helm/Kustomize)
2. **Versioned & immutable** — Git is the single source of truth, full audit trail via commit history
3. **Pulled automatically** — an agent (ArgoCD) pulls/applies changes rather than CI pushing to the cluster (pull vs push model — key security distinction)
4. **Continuously reconciled** — drift between Git and live state is detected and (optionally) auto-corrected

### Push (traditional CI/CD) vs Pull (GitOps) — frequently asked
| | Push (Jenkins/CI applies to cluster) | Pull (ArgoCD) |
|---|---|---|
| Credentials | CI needs cluster-admin-like credentials sitting in the CI system | Cluster credentials never leave the cluster; ArgoCD runs in-cluster and pulls from Git |
| Drift | No ongoing enforcement — manual `kubectl` changes silently drift | Continuously detected & can be auto-healed |
| Audit trail | Scattered across CI logs | Git commit history = full audit trail (huge selling point for regulated industries) |
| Blast radius of compromised CI | High — CI has direct cluster write access | Lower — CI only needs Git write access; ArgoCD pulls |

---

## 2. Core Objects / CRDs

| Resource | Purpose |
|---|---|
| **Application** | Core CRD — maps a Git source (repo/path/revision) to a destination (cluster/namespace); the unit of deployment |
| **AppProject** | Groups Applications, restricts what repos/clusters/resource kinds/namespaces they're allowed to use — RBAC & governance boundary |
| **ApplicationSet** | Generates many Applications from a template (e.g., one per cluster, per environment, per Git directory) — key for multi-cluster/multi-tenant scale |

### Example Application
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd
spec:
  project: payments
  source:
    repoURL: https://github.com/org/payments-api-config.git
    targetRevision: main
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true          # delete resources removed from Git
      selfHeal: true        # revert manual/out-of-band cluster changes
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Example AppProject (governance boundary)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  sourceRepos:
    - "https://github.com/org/payments-*"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "payments*"
  clusterResourceWhitelist: []            # deny cluster-scoped resources by default
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
  roles:
    - name: readonly
      policies:
        - p, proj:payments:readonly, applications, get, payments/*, allow
```

### ApplicationSet — Git generator example (multi-env/multi-cluster fanout)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
spec:
  generators:
    - git:
        repoURL: https://github.com/org/services-config.git
        revision: main
        directories:
          - path: "services/*"
  template:
    metadata:
      name: "{{path.basename}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/org/services-config.git
        targetRevision: main
        path: "{{path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{path.basename}}"
```
Generators: `git` (dirs/files), `cluster` (one App per registered cluster — common for fleet rollouts), `list`, `matrix` (combine generators), `pullRequest` (preview envs per open PR), `scm-provider`

---

## 3. Sync Mechanics

### Sync Status vs Health Status (commonly confused — clarify this in interview)
- **Sync Status** — does live state match Git? (`Synced` / `OutOfSync`)
- **Health Status** — is the resource actually working? (`Healthy` / `Progressing` / `Degraded` / `Missing`) — ArgoCD has built-in health checks per resource kind (Deployment ready replicas, Ingress has an address, Job completed, etc.), extensible via Lua for CRDs

### Sync Policies
- **Manual** — default; sync triggered via UI/CLI/API
- **Automated** — auto-sync on Git change detection
  - `prune: true` — deletes resources removed from Git (off by default — safety)
  - `selfHeal: true` — reverts manual `kubectl` drift back to Git state automatically

### Sync Waves & Hooks (ordering control — important for dependency-ordered rollouts)
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"     # lower runs first; can be negative
```
Hooks (similar to Helm hooks): `PreSync`, `Sync`, `PostSync`, `SyncFail` via `argocd.argoproj.io/hook` annotation — common use: DB migration Job as `PreSync`.

### Resource Pruning & Ignoring Differences
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas          # e.g., ignore fields managed by HPA
```

---

## 4. Sources ArgoCD Supports

- Plain YAML manifests / Kustomize overlays
- **Helm charts** (local or from a Helm repo) — `spec.source.helm.valueFiles`, `.helm.parameters` for `--set`-style overrides
- **Jsonnet**
- Directory of manifests with recursion
- **Multiple sources per Application** (newer feature) — e.g., a Helm chart + a separate values file repo combined

---

## 5. Multi-Cluster & Multi-Tenancy Patterns

- ArgoCD can manage remote clusters via registered cluster secrets (`argocd cluster add`) — one ArgoCD control plane can deploy to many clusters ("hub and spoke")
- **App of Apps pattern** — a root Application whose only job is to declare other Applications; enables bootstrapping an entire cluster's app set from one Git commit, and lets teams self-service by adding an Application manifest to a shared repo
- **ApplicationSet cluster generator** — auto-creates one Application per registered cluster, ideal for fleet-wide add-ons (e.g., deploy a monitoring stack to every cluster automatically)
- **AppProjects** as the tenancy boundary — restrict which repos/clusters/resource kinds/destinations each team's Applications can touch, plus RBAC roles scoped per project

---

## 6. Security & RBAC (senior-level, esp. regulated industries)

- ArgoCD has its **own RBAC system** (`argocd-rbac-cm` ConfigMap) layered on top of K8s RBAC — policies like:
  ```
  p, role:payments-dev, applications, sync, payments/*, allow
  g, jane@bank.com, role:payments-dev
  ```
- SSO integration (OIDC/SAML/Dex) — typically wired to corporate IdP (Okta/AzureAD) rather than local users, critical for audit in banking environments
- **Repo credentials** stored as K8s Secrets (or via external secret managers) — never in the Application manifest itself
- ArgoCD's in-cluster ServiceAccount typically needs broad permissions to apply arbitrary manifests — worth discussing least-privilege patterns (separate ArgoCD instances per tenant/cluster, or `resource.exclusions`/whitelists in AppProjects to limit blast radius)
- **Config drift as a security control** — `selfHeal` means unauthorized manual changes get reverted automatically, which is a strong compliance story ("nothing survives in the cluster that isn't in Git")
- Audit trail = Git commit history + ArgoCD's own event log — pairs well with required PR approvals for change control

---

## 7. CLI Cheat Sheet

```bash
# Login
argocd login argocd.company.com --sso

# App management
argocd app create payments-api --repo https://github.com/org/config.git \
  --path overlays/prod --dest-server https://kubernetes.default.svc --dest-namespace payments

argocd app list
argocd app get payments-api
argocd app sync payments-api
argocd app sync payments-api --prune
argocd app diff payments-api                # show drift between Git and live state
argocd app history payments-api
argocd app rollback payments-api <revision-id>

argocd app set payments-api --sync-policy automated --auto-prune --self-heal

# Cluster management
argocd cluster add my-context
argocd cluster list

# Project management
argocd proj create payments
argocd proj allow-cluster-resource payments '*' '*'
```

---

## 8. Common Gotchas / Real-World Pitfalls

- Forgetting `prune: true` means deleted-from-Git resources silently linger in the cluster
- `selfHeal` fighting with HPA/VPA — a controller adjusting `replicas` looks like drift unless you add it to `ignoreDifferences`
- Secrets in Git — plaintext Secrets committed to the config repo is a classic anti-pattern; use **Sealed Secrets**, **External Secrets Operator**, or SOPS-encrypted values with a Helm/Kustomize plugin
- Sync waves misordered → CRDs applied after the custom resources that depend on them → sync failures
- One giant ArgoCD instance managing every team's Applications without AppProject boundaries → any team's compromised repo creds can touch anything — tenancy design matters
- Helm value overrides done through the ArgoCD UI/`--set` outside of Git → breaks the "Git is single source of truth" GitOps principle; prefers values committed to Git
- App-of-Apps root app itself needs careful RBAC — it can create/delete other Applications, effectively a privilege-escalation path if misconfigured

---

## 9. Interview Questions

### Conceptual / Fundamentals
1. What is GitOps, and how does ArgoCD implement it? Contrast push vs pull deployment models.
2. What's the difference between Sync Status and Health Status in ArgoCD?
3. What is an `AppProject` for, and how is it different from just using an `Application`?
4. Explain `prune` and `selfHeal` — what do they each do, and why are they separate flags?
5. What is the App-of-Apps pattern, and what problem does it solve?
6. What generators does `ApplicationSet` support, and when would you use `matrix` vs `cluster` vs `git`?

### Practical / Scenario-based
7. A Deployment's replica count keeps flipping between two values and ArgoCD shows it as constantly `OutOfSync` — what's likely happening, and how do you fix it? *(→ HPA changing replicas fights selfHeal; use `ignoreDifferences`)*
8. You deleted a manifest from your config repo, but the resource is still running in the cluster — why, and how do you prevent that in the future? *(→ `prune: false` by default; enable pruning, or explain risk trade-off of always-on pruning)*
9. How would you order a DB migration Job to run before a Deployment rollout, and roll back automatically if the migration fails? *(→ PreSync hook + SyncFail hook, sync waves)*
10. Multiple teams share one ArgoCD instance — how do you make sure Team A can't deploy into Team B's namespace or use unapproved container registries? *(→ AppProject `destinations`, `sourceRepos`, resource whitelists, RBAC roles)*
11. You need to bootstrap 50 clusters with the same baseline set of add-ons (monitoring, logging, ingress controller) — how do you avoid creating 50 sets of manifests by hand? *(→ ApplicationSet cluster generator + App-of-Apps)*
12. Someone `kubectl edit`'d a ConfigMap directly in prod during an incident — what does ArgoCD do about that, and how do you make sure it's still reflected/reconciled correctly afterward? *(→ selfHeal reverts drift; correct fix is to commit the change to Git, not edit the cluster)*
13. A sync is failing because a CRD isn't installed yet when the custom resource using it gets applied — how do you fix the ordering? *(→ sync waves, or `Skip`/`Validate=false` sync options, install CRDs in an earlier wave)*

### Design / Trade-off Discussion (senior-level)
14. How would you structure your Git repos for a GitOps setup at scale — mono-repo vs repo-per-service vs repo-per-environment? What trade-offs matter?
15. How do you keep an audit trail suitable for a regulated bank's change-control process using ArgoCD — what evidence would you point an auditor to?
16. What's your approach to secrets management in a GitOps workflow, given that "everything in Git" conflicts with "secrets shouldn't be in Git"?
17. When would you run separate ArgoCD instances per team/cluster vs one central instance managing everything — what's the security/operational trade-off?
18. How does ArgoCD fit alongside Helm and Kustomize — are they complementary or competing, and how would you decide which combination to use for a given team?

---

*ArgoCD interviews for a bank almost always pivot to "how do you prove to an auditor that what's running matches what was approved" — be ready to connect Git PR approvals, sync history, RBAC, and selfHeal into one coherent change-control story, not just describe the mechanics.*
