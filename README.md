# AutoCare Deployment

Kubernetes, Helm and CI/CD deployment automation for **AutoCare – Vehicle Service Management Platform**, targeting **Amazon EKS**.

This repository is responsible **only** for deployment: Kubernetes manifests (via Helm), the Jenkins deployment pipeline, and operational scripts (deploy/rollback/verify). It does not build the application and does not create AWS infrastructure.

---

## 1. Project Overview

AutoCare is split across three repositories, each with a single responsibility:

| Repository | Responsibility |
|---|---|
| [`autocare-platform`](https://github.com/Srikanth-IT-Solutions/autocare-platform) | Java 17 / Spring Boot application source, Maven build, unit tests, `Dockerfile`, application config |
| [`autocare-infrastructure`](https://github.com/Srikanth-IT-Solutions/autocare-infrastructure) | Terraform: VPC, subnets, NAT, EKS, managed node groups, RDS, ECR, IAM, Pod Identity/IRSA, Secrets Manager, CloudWatch |
| **`autocare-deployment`** (this repo) | Kubernetes/Helm manifests, Service/Ingress/ALB config, `SecretProviderClass`, HPA/PDB, ConfigMap/ServiceAccount, Jenkins deployment pipeline, rollback/validation scripts |

This repository never contains Terraform code, never provisions AWS infrastructure, and never runs MySQL inside Kubernetes.

---

## 2. Architecture

### Deployment pipeline

```
Developer → GitHub → Jenkins → Maven Build & Test → SonarQube → Docker Build → Amazon ECR
                                                                                     │
                                                                                     ▼
                                                          Jenkins (this repo) → Helm → Amazon EKS
```

The CI pipeline (in `autocare-platform`) builds, tests and pushes an image to ECR. **This repository's Jenkins pipeline never rebuilds the application** — it only takes an already-built, immutable image tag and deploys it.

### Runtime / traffic flow

```
Internet → AWS Application Load Balancer → AWS Load Balancer Controller
         → Kubernetes Service (ClusterIP) → AutoCare Pods → Amazon RDS MySQL (private)
```

- EKS worker nodes run in **private subnets**.
- RDS runs in **private DB subnets**, no public access.
- The application is **never** exposed via `NodePort`.
- Ingress uses `ingressClassName: alb`, `target-type: ip`, `scheme: internet-facing`.
- No Route 53 record or custom domain is required — the application is reachable immediately via the ALB's own auto-generated public DNS name.

### Secrets flow

```
AWS Secrets Manager (autocare/<env>/database)
   → SecretProviderClass (provider: aws / ASCP)
   → Secrets Store CSI Driver (mounts + syncs)
   → Kubernetes Secret (autocare-<env>-db-credentials)
   → AutoCare Pod env vars (secretKeyRef: DB_HOST, DB_PORT, DB_NAME, DB_USERNAME, DB_PASSWORD)
   → Spring Boot → Amazon RDS MySQL
```

The AWS secret is the single source of truth. No database credentials are ever stored in Git, values files, ConfigMaps, or the Jenkinsfile.

### Helm architecture

One reusable chart (`helm/autocare`) with environment differences expressed purely through values files — no duplicated templates:

```
values.yaml        (defaults, shared)
  └─ values-dev.yaml   (overrides: 1 replica, HTTP, HPA/PDB off)
  └─ values-prod.yaml  (overrides: 2+ replicas, HPA/PDB on, HTTPS-ready)
```

### Environment strategy

| | dev | prod |
|---|---|---|
| Replicas | 1 | 2 (HPA: 2–5) |
| HPA | disabled | enabled (CPU 70% / Memory 75%) |
| PDB | disabled | enabled (minAvailable: 1) |
| Ingress | HTTP only | HTTP by default, HTTPS when `certificateArn` is set |
| Secret | `autocare/dev/database` | `autocare/prod/database` |
| Image tag | any | must not be `latest` (enforced by Jenkins/scripts) |

### Security architecture

- `runAsNonRoot: true`, no root user
- `allowPrivilegeEscalation: false`
- All Linux capabilities dropped (`capabilities.drop: [ALL]`)
- `seccompProfile: RuntimeDefault`
- `readOnlyRootFilesystem: true` (with a small `emptyDir` mounted at `/tmp` for runtime writes)
- No `privileged` containers
- Dedicated `ServiceAccount` (never `default`), IRSA-annotation-ready / EKS Pod Identity–compatible
- Least-privilege IAM: the pod's role should only ever be granted `secretsmanager:GetSecretValue` scoped to the specific AutoCare secret — never `secretsmanager:*` or `AdministratorAccess`
- No AWS credentials hard-coded anywhere in this repo
- Immutable image tags; `latest` is rejected for production

---

## 3. Repository Structure

```
autocare-deployment/
├── helm/
│   └── autocare/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-prod.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── configmap.yaml
│           ├── serviceaccount.yaml
│           ├── secretproviderclass.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── NOTES.txt
├── scripts/
│   ├── deploy.sh
│   ├── rollback.sh
│   └── verify.sh
├── Jenkinsfile
├── README.md
├── .gitignore
└── helm/autocare/.helmignore
```

---

## 4. Prerequisites

Provisioned by `autocare-infrastructure` (Terraform) **before** this repository can deploy anything:

- An Amazon EKS cluster with worker nodes in private subnets
- Amazon ECR repository containing the built application image
- Amazon RDS MySQL instance in private DB subnets
- An AWS Secrets Manager secret named `autocare/<env>/database` containing `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`
- An IAM role (IRSA or EKS Pod Identity) scoped to `secretsmanager:GetSecretValue` on that specific secret

Installed at cluster level (also by infrastructure, not by this repo):

- **AWS Load Balancer Controller** — required for the `ingressClassName: alb` Ingress to provision an ALB
- **Secrets Store CSI Driver** + **AWS Secrets and Configuration Provider (ASCP)** — required for `SecretProviderClass` to retrieve and sync secrets
- **Kubernetes Metrics Server** — required only if `autoscaling.enabled: true` (HPA)

Local tooling:

- `kubectl` (matching your cluster's Kubernetes version)
- `helm` v3.12+
- `aws` CLI v2
- Bash (for the scripts) — Jenkins agents should also have all the above installed

---

## 5. EKS Requirements

- Cluster must have OIDC provider enabled (for IRSA) or EKS Pod Identity Agent add-on installed (for Pod Identity)
- Worker nodes in private subnets with NAT egress to reach ECR/Secrets Manager/RDS
- `kubectl get nodes` and `kubectl get pods -n autocare` should succeed once `aws eks update-kubeconfig` has been run

## 6. AWS Load Balancer Controller Requirement

The Ingress template emits `alb.ingress.kubernetes.io/*` annotations and `ingressClassName: alb`. Without the AWS Load Balancer Controller running in-cluster (installed by the infrastructure layer via Helm/Terraform), no ALB will be provisioned and the Ingress will remain without an address.

## 7. Secrets Store CSI Driver Requirement

Without the driver + ASCP provider installed, the `SecretProviderClass` object will be accepted by the API server but the CSI volume mount in the Deployment will fail to mount, and the pod will not start. This must be installed at the infrastructure level — see `templates/secretproviderclass.yaml` for details.

## 8. AWS Secrets Manager Requirement

Each environment expects a secret at `autocare/<environment>/database` (e.g. `autocare/dev/database`, `autocare/prod/database`), created and populated by `autocare-infrastructure` — never by this repository. It must be a JSON object shaped like this (illustrative only — never commit real values):

```json
{
  "DB_HOST": "autocare-dev.xxxxxxxxxxxx.ap-south-1.rds.amazonaws.com",
  "DB_PORT": "3306",
  "DB_NAME": "autocare",
  "DB_USERNAME": "autocare_app",
  "DB_PASSWORD": "REPLACE_ME_IN_SECRETS_MANAGER"
}
```

## 9. IAM / Pod Identity Requirement

The `ServiceAccount` created by this chart (`templates/serviceaccount.yaml`) is the IAM binding point:

- **IRSA**: set `serviceAccount.annotations."eks.amazonaws.com/role-arn"` (via `--set` or a values override) to the IAM role ARN.
- **EKS Pod Identity**: leave annotations empty; the infrastructure layer creates an `aws eks-pod-identity-association` targeting this ServiceAccount's name (`autocare`) and namespace (`autocare`).

Either way, the IAM role must be least-privilege: `secretsmanager:GetSecretValue` on the one AutoCare secret ARN only.

## 10. ECR Requirement

An ECR repository must already contain the image tag being deployed. Jenkins and `scripts/deploy.sh` both call `aws ecr describe-images` before deploying and fail fast if the tag is missing.

---

## 11. Helm Installation

```bash
# lint
helm lint ./helm/autocare -f ./helm/autocare/values-dev.yaml

# render (dry, no cluster needed)
helm template autocare ./helm/autocare \
  -f ./helm/autocare/values-dev.yaml \
  --set image.repository=<account-id>.dkr.ecr.ap-south-1.amazonaws.com/autocare \
  --set image.tag=<tag>

# dry-run against a real cluster
helm upgrade --install autocare ./helm/autocare \
  --namespace autocare --create-namespace \
  -f ./helm/autocare/values-dev.yaml \
  --set image.repository=<account-id>.dkr.ecr.ap-south-1.amazonaws.com/autocare \
  --set image.tag=<tag> \
  --dry-run
```

Any value in `values.yaml` can be overridden this way at deploy time — most commonly `image.repository`/`image.tag` (set by Jenkins) and IRSA/ingress settings that vary per AWS account. For example, to set an IRSA role ARN and pin an ingress hostname without editing the chart:

```bash
helm upgrade --install autocare ./helm/autocare \
  --namespace autocare --create-namespace \
  -f ./helm/autocare/values-dev.yaml \
  --set image.repository=<account-id>.dkr.ecr.ap-south-1.amazonaws.com/autocare \
  --set image.tag=<tag> \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<account-id>:role/autocare-dev-secrets-role \
  --set ingress.hostname="" \
  --wait --atomic --timeout 10m
```

(`ingress.hostname` is left empty intentionally in dev/prod — see section 14 — so the app is reachable via the ALB's own auto-generated DNS name without needing Route 53.)

## 12. kubectl Configuration

```bash
aws eks update-kubeconfig --name autocare-dev-eks --region ap-south-1
kubectl get nodes
```

## 13. Dev Deployment

```bash
./scripts/deploy.sh dev <image-tag> <ecr-repository> ap-south-1 autocare-dev-eks autocare
```

or manually:

```bash
helm upgrade --install autocare ./helm/autocare \
  --namespace autocare --create-namespace \
  -f ./helm/autocare/values-dev.yaml \
  --set image.repository=<ecr-repo> \
  --set image.tag=<tag> \
  --wait --atomic --timeout 10m
```

## 14. Production Deployment

```bash
./scripts/deploy.sh prod <image-tag> <ecr-repository> ap-south-1 autocare-prod-eks autocare
```

Production additionally enforces (via `scripts/deploy.sh` and the Jenkinsfile): image tag must not be `latest`.

## 15. Jenkins Deployment

The `Jenkinsfile` pipeline takes these parameters: `ENVIRONMENT`, `IMAGE_TAG`, `ECR_REPOSITORY`, `AWS_REGION`, `EKS_CLUSTER_NAME`, `NAMESPACE`.

Stages: Checkout → Validate Environment → Helm Version → Helm Lint → Helm Template → AWS Authentication → Update Kubeconfig → Verify EKS Access → Verify ECR Image → Helm Dry Run → Helm Upgrade/Install → Wait for Rollout → Verify Pods → Verify Service → Verify Ingress → Display Application Information.

AWS authentication uses a Jenkins "AWS Credentials" credential (`aws-eks-deployer`, configurable in `Jenkinsfile`'s `environment` block) — never hard-coded keys. If Jenkins agents already run under an IAM instance role or IRSA, remove the `withCredentials` wrapper and the same `aws`/`kubectl` commands will pick up ambient credentials.

The pipeline fails fast (and does not proceed) on: missing parameters, `latest` tag in prod, missing values file, missing ECR image, failed Helm lint/dry-run, failed rollout, or unhealthy pods/service/ingress.

## 16. Rollback

```bash
helm history autocare -n autocare          # identify releases
./scripts/rollback.sh autocare              # roll back to previous revision
./scripts/rollback.sh autocare 3            # roll back to a specific revision
kubectl rollout status deployment/autocare -n autocare   # verify
```

`scripts/rollback.sh` wraps `helm rollback ... --wait` and re-verifies rollout status afterward. Jenkins itself does not auto-rollback on failure (Helm's `--atomic` flag already reverts a failed upgrade to the prior working revision); use `rollback.sh` for a manual rollback to an older, previously-successful revision.

## 17. Troubleshooting

```bash
kubectl get pods -n autocare
kubectl describe pod <pod-name> -n autocare
kubectl logs <pod-name> -n autocare
kubectl get svc -n autocare
kubectl get ingress -n autocare
kubectl rollout status deployment/autocare -n autocare
kubectl get events -n autocare --sort-by='.lastTimestamp'
```

Common issues:

- **Pod stuck in `ContainerCreating`, CSI mount error** → Secrets Store CSI Driver/ASCP not installed, or the `SecretProviderClass` name doesn't match `secrets.secretProviderClass.name`.
- **`ImagePullBackOff`** → image tag not pushed to ECR, or the node IAM role/VPC endpoint lacks ECR pull access.
- **Ingress has no `ADDRESS`** → AWS Load Balancer Controller not installed/running, or subnets aren't tagged for ALB discovery (infrastructure-layer concern).
- **Pod `CrashLoopBackOff` on DB connection** → verify the synced Secret (`kubectl get secret <syncSecretName> -n autocare -o yaml`) actually contains `DB_HOST/PORT/NAME/USERNAME/PASSWORD`, and that the pod's IAM role can read the AWS secret.

## 18. Monitoring

Out of scope for this repository by design (see "Do Not Over-Engineer" below). The application logs to stdout/stderr, which Kubernetes collects natively:

```
AutoCare Pod → stdout/stderr → Kubernetes container logs → (future) ELK
AWS resource logs/metrics → CloudWatch (infrastructure layer)
```

## 19. Security

See the "Security architecture" section above. Summary of hard rules enforced by this repo:

- No AWS access keys, database passwords, or kubeconfig in Git (`.gitignore`, and no values file ever holds a real secret)
- No privileged/root containers, no `NodePort`, no public RDS access from this layer
- No broad IAM permissions requested by the chart — the ServiceAccount is just an identity; least-privilege policy is defined and attached in `autocare-infrastructure`
- Immutable, explicit image tags only

## 20. Future GitOps / Argo CD Integration

The chart is intentionally kept declarative, environment-parameterized via values files, and free of imperative logic, so it can later be adopted by Argo CD without modification:

```
GitHub (this repo) → Argo CD → EKS
```

Argo CD is **not** installed or configured by this repository today — this is a documented future enhancement, not a prerequisite.

---

## Do Not Over-Engineer

This is a real-world, production-oriented DevOps training project. It deliberately does **not** include a service mesh (Istio), Kafka, Redis, RabbitMQ, Argo CD, Prometheus/Grafana, or an ELK deployment. These may be added later as separate modules. The core, complete path is:

```
Java application → Docker → ECR → EKS → RDS → Secrets Manager → ALB → Jenkins → Helm
```
