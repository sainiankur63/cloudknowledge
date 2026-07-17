# Helm Cheatsheet & Interview Questions — Senior DevOps Prep

---

## 1. Core Concepts

| Term | Meaning |
|---|---|
| **Chart** | A package of pre-configured K8s resources (templates + metadata) |
| **Release** | An instance of a chart deployed into a cluster (same chart can be installed multiple times as different releases) |
| **Repository** | A place charts are stored/shared (HTTP server serving an `index.yaml`, or OCI registry) |
| **Values** | Configuration input (`values.yaml`) injected into templates |
| **Chart.yaml** | Chart metadata — name, version, appVersion, dependencies |
| **Tiller** | Helm 2's server-side component — **removed in Helm 3** (major interview point, see below) |

### Helm 2 vs Helm 3 (very commonly asked)
- Helm 3 removed **Tiller** — no longer needs a cluster-side privileged component; client (`helm` CLI) talks directly to the K8s API server using your kubeconfig/RBAC → eliminates a major security hole (Tiller ran with broad, often cluster-admin, permissions)
- Release info stored as **Secrets** (default) in the release's own namespace, not in a central `kube-system` ConfigMap
- **Releases are now namespace-scoped**, allowing same release name in different namespaces
- 3-way strategic merge patch on upgrade (compares chart, live state, and previous release) instead of 2-way — reduces config drift issues
- `helm template`, JSON Schema validation for values (`values.schema.json`), library charts, native support for OCI registries added later

---

## 2. Chart Structure

```
mychart/
├── Chart.yaml          # metadata: name, version, appVersion, dependencies
├── values.yaml          # default configuration values
├── values.schema.json   # optional JSON schema to validate values
├── charts/               # subcharts / dependencies (.tgz or unpacked)
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── _helpers.tpl     # reusable template snippets/functions
│   ├── NOTES.txt        # post-install usage notes shown to user
│   └── tests/
│       └── test-connection.yaml
└── .helmignore
```

### Chart.yaml essentials
```yaml
apiVersion: v2
name: mychart
version: 1.2.0        # chart version (semver)
appVersion: "3.4.0"    # version of the app it deploys (independent of chart version)
dependencies:
  - name: postgresql
    version: "12.x.x"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
```
Interview distinction: **`version`** = chart's own version; **`appVersion`** = version of the underlying application — the two evolve independently.

---

## 3. Templating Essentials

### Built-in objects
- `.Values` — from values.yaml / `--set` / `-f`
- `.Release` — Name, Namespace, IsInstall, IsUpgrade, Revision
- `.Chart` — Chart.yaml fields
- `.Files` — access non-template files in chart
- `.Capabilities` — K8s version, API availability

### Common functions/pipelines
```yaml
name: {{ .Release.Name }}-{{ .Chart.Name }}
replicas: {{ .Values.replicaCount | default 1 }}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
{{- if .Values.ingress.enabled }}
...
{{- end }}
{{- with .Values.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- range .Values.env }}
- name: {{ .name }}
  value: {{ .value | quote }}
{{- end }}
```

### `_helpers.tpl` (named templates, DRY reuse)
```yaml
{{- define "mychart.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```
Called via `{{ include "mychart.fullname" . }}` — `include` (vs `template`) is preferred since it can be piped (e.g. `| nindent 4`), whereas `template` cannot.

### Whitespace control
- `{{-` trims preceding whitespace/newline, `-}}` trims following — critical for clean YAML output; a very common "why is my YAML broken" debugging question

---

## 4. CLI Commands Cheat Sheet

```bash
# Repo management
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo nginx

# Install / upgrade
helm install myrelease ./mychart -f values-prod.yaml --namespace prod --create-namespace
helm upgrade myrelease ./mychart --set image.tag=1.2.3
helm upgrade --install myrelease ./mychart   # idempotent install-or-upgrade (common in CI/CD)

# Dry runs / debugging
helm install myrelease ./mychart --dry-run --debug
helm template myrelease ./mychart            # render locally, no cluster call
helm lint ./mychart                           # static validation

# Rollback / history
helm history myrelease
helm rollback myrelease 2                     # rollback to revision 2

# Inspect
helm status myrelease
helm get values myrelease
helm get manifest myrelease

# Uninstall
helm uninstall myrelease
helm uninstall myrelease --keep-history        # allows future rollback reference

# Dependencies
helm dependency update ./mychart
helm dependency build ./mychart

# Packaging
helm package ./mychart
helm push mychart-1.2.0.tgz oci://myregistry.azurecr.io/helm
```

---

## 5. Values Precedence (frequently tested — get the order right)

Highest → lowest priority:
1. `--set` / `--set-string` / `--set-json` (CLI flags)
2. `-f custom-values.yaml` (last `-f` wins if multiple)
3. Chart's own `values.yaml`
4. Subchart's own `values.yaml` (unless overridden by parent)

Parent chart can override subchart values via a top-level key matching the subchart name in the parent's `values.yaml`:
```yaml
postgresql:
  auth:
    postgresPassword: "secret"
```

---

## 6. Hooks

Helm hooks let you run Jobs/Pods at specific points in the release lifecycle.

| Hook | When |
|---|---|
| `pre-install` / `post-install` | Before/after resources are created |
| `pre-upgrade` / `post-upgrade` | Before/after upgrade |
| `pre-delete` / `post-delete` | Before/after deletion |
| `pre-rollback` / `post-rollback` | Before/after rollback |
| `test` | Run via `helm test` — validation Pods |

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-install
    "helm.sh/hook-weight": "-5"     # lower runs first
    "helm.sh/hook-delete-policy": hook-succeeded,before-hook-creation
```
Common use: DB migration Job as a `pre-upgrade` hook. Hook resources are **not tracked as part of the release** by default and not deleted on `helm uninstall` unless a delete-policy is set — a classic gotcha.

---

## 7. Advanced / Senior-Level Topics

- **Library charts** (`type: library` in Chart.yaml) — provide reusable template snippets, produce no deployable resources themselves; used for standardizing boilerplate across many microservice charts (common in large orgs)
- **OCI registries** — Helm 3.8+ supports pushing/pulling charts as OCI artifacts (`helm push`, `oci://` refs) — replacing classic chart-museum-style repos in many enterprises
- **Post-rendering** (`--post-renderer`) — pipe rendered manifests through a tool like Kustomize for last-mile patches without forking the chart
- **Chart testing** — `helm unittest` plugin, `ct` (chart-testing) tool for CI lint/install testing, `helm test` for post-deploy smoke tests
- **Secrets in values** — plain values.yaml is not encrypted; use **Helm Secrets plugin (SOPS)**, **Sealed Secrets**, or external secret operators rather than committing plaintext secrets
- **GitOps integration** — ArgoCD/Flux natively support Helm charts as a source; tension point to discuss: templating (Helm) vs overlay/patch (Kustomize) philosophies, and many shops combine both (Helm for packaging, Kustomize/post-render for env overlays)
- **Atomic upgrades**: `helm upgrade --atomic` — automatically rolls back on failure, combine with `--timeout`
- **`--wait` flag** — waits for resources to reach ready state before marking release successful; essential for CI/CD gating

---

## 8. Interview Questions

### Conceptual / Fundamentals
1. What problem does Helm solve that raw `kubectl apply` doesn't?
2. Explain the difference between a chart, a release, and a repository.
3. What changed between Helm 2 and Helm 3, and why was Tiller removed?
4. What's the difference between `Chart.yaml`'s `version` and `appVersion`?
5. How does Helm decide the order in which resources are installed?
6. Explain values precedence — if a value is set via `--set`, in `values.yaml`, and in a subchart, which wins?
7. What is the difference between `template` and `include` functions in a chart?
8. Why would you use `{{-` and `-}}` in a template — what problem does it solve?

### Practical / Scenario-based
9. A `helm upgrade` failed halfway through and left the cluster in a broken state — how do you recover? *(→ `helm rollback`, `--atomic` for future upgrades, check `helm history`)*
10. You need to inject a Kubernetes Secret's value into a chart without storing it in Git — how would you do that? *(→ external-secrets operator / Sealed Secrets / SOPS + helm-secrets plugin, avoid plaintext in values.yaml)*
11. How would you run a database migration exactly once during a Helm upgrade, before the new app version starts serving traffic? *(→ `pre-upgrade` hook with appropriate weight)*
12. Two teams want to share common labels/annotations logic across 20 microservice charts — how do you avoid copy-pasting templates? *(→ library chart)*
13. How do you validate a chart renders correctly without actually deploying it (e.g., in a CI pipeline)? *(→ `helm template`, `helm lint`, `ct lint`)*
14. You want zero-downtime deploys gated in CI so the pipeline only reports success if pods actually became healthy — what Helm flags do you use? *(→ `--wait --atomic --timeout`)*
15. How does Helm distinguish resources it manages from resources applied manually via `kubectl` in the same namespace? *(→ ownership via Secret release metadata + `app.kubernetes.io/managed-by: Helm` label / helm.sh annotations; manual kubectl-applied resources aren't tracked and can cause drift)*
16. What happens to resources created by a `pre-install` hook when you run `helm uninstall`? *(→ not deleted by default unless a hook-delete-policy is set — potential orphaned resources)*

### Design / Trade-off Discussion (senior-level)
17. When would you choose Kustomize over Helm, or use them together?
18. How do you manage Helm chart versioning and promotion across dev → staging → prod in a regulated environment (e.g., banking) — what does your release/audit trail look like?
19. How do you handle chart dependency version pinning to avoid an untested subchart upgrade silently breaking prod?
20. What's your strategy for secrets across many charts/environments at scale, and how does it hold up to a security audit?

---

*Pairs well with the Kubernetes cheatsheet — Helm questions in senior interviews often pivot into "and how does that interact with your GitOps/CI-CD pipeline," so be ready to connect Helm mechanics to your deployment pipeline story.*
