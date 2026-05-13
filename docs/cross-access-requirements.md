# Cross Insurance — Access Requirements for the Cloud Build Integration

> Document prepared for the **Cross Insurance** IT team. It enumerates the
> GCP and GitHub actions required to deploy, in your environment, the
> Terraform / Cloud Build pipeline (automatic plan on `main`, manual apply
> with mandatory approval) currently running in our internal sandbox
> (`ks-crossinsurance-proj-test-01..04`).

---

## Operating model

This integration follows the same separation of duties already in place
for the projects Filipe configured:

| Party | Responsibility |
|---|---|
| **Cross Insurance** | Owns and operates the GCP environment. Creates the Service Account, grants IAM, connects the repository, creates Cloud Build triggers, approves applies. |
| **Kloudstax** | Owns the Terraform code, the Cloud Build YAML pipelines, and the supporting documentation. Provides ongoing maintenance and support. Does **not** require administrative access to your GCP environment or to your GitHub organization. |

All operational permissions are granted to a **dedicated, least-privilege
Service Account** (the "Terraform CI SA"). The Cross team grants the
roles listed in §3 to that SA and attaches it to the Cloud Build
triggers. Kloudstax does not need any direct human access to the GCP
projects in order for the pipeline to function.

---

## Summary of required actions

| # | Action | Scope | Granted by |
|---|---|---|---|
| 1 | Create one **Terraform CI Service Account** in a Cross-controlled project (recommended location: a dedicated `terraform`/`ci` project, similar to the one Filipe uses today). See §3. | Cross GCP | Project Owner / Service Account Admin |
| 2 | Grant the granular IAM roles listed in §3 to that Service Account on the workload projects, on the Shared VPC host project, and on the GCS buckets used for remote state and CIDR registry. | Cross GCP | IAM Admin / Storage Admin |
| 3 | Install the **Cloud Build GitHub App** on the Cross GitHub organization and grant it access to the Terraform repository. See §4. | Cross GitHub Organization | GitHub Org Admin |
| 4 | Create (or confirm) the two **GCS buckets** that will store the Terraform remote state and the central CIDR registry. See §5. | Cross GCP | Storage Admin |
| 5 | In each workload project, create the **Cloud Build triggers** (one plan trigger + one apply trigger) using the Service Account from §1. See §6 and the companion document `docs/cross-cloudbuild-setup.md`. | Cross GCP | Cloud Build Editor |
| 6 | (Optional) Grant **read-only Cloud Build access** to a Kloudstax contact (`marcelo.santoro@kloudstax.com`) so we can observe build logs while providing support. See §7. | Cross GCP | Project IAM Admin |

---

## 1. Context

We are deploying, in your environment, the same Infrastructure-as-Code
pipeline already running in our internal sandbox:

- A **Terraform** monorepo hosted on GitHub, with one stack per workload
  project.
- **Cloud Build** running `terraform plan` automatically on every push to
  the `main` branch and `terraform apply` only on **manual invocation
  with mandatory approval** (`require-approval`) by a second person.
- **Remote state** stored in a single Google Cloud Storage bucket, with a
  separate object prefix per stack.
- A **central CIDR registry** kept in GCS (`cidr-registry.txt`) and
  validated on every plan and apply, in order to prevent overlapping
  ranges across projects.

In order to extend this pipeline to your environment, we require the
actions detailed in the following sections.

---

## 2. What the Cross Insurance team will operate

All of the following activities are performed by the Cross IT team:

- Creating and rotating the Terraform CI Service Account.
- Granting and reviewing the IAM bindings listed in §3.
- Installing the Cloud Build GitHub App and connecting the repository to
  each workload project.
- Creating, editing, disabling and approving the Cloud Build triggers.
- Reviewing the build logs and approving or rejecting `terraform apply`
  runs.

Kloudstax provides the Terraform code, the `cloudbuild-*.yaml`
pipelines, the deployment scripts (`deploy.sh`), and this documentation.
We support the Cross team during integration and on an ongoing basis,
but we do not need administrative access to perform the tasks above.

---

## 3. Terraform CI Service Account

### 3.1. Naming and location

We recommend creating **one** Service Account dedicated to the Terraform
pipeline:

- **Recommended name:** `sa-terraform-ci`
- **Recommended host project:** the same project Filipe uses today for
  the existing Cloud Build pipelines (typically a dedicated
  `terraform`/`ci` project), so that the audit story is consistent across
  all of your IaC pipelines.
- **Resulting email address:**
  `sa-terraform-ci@<terraform-project>.iam.gserviceaccount.com`.

### 3.2. Required IAM roles

The Service Account must receive the roles below. These are the same
permissions used by the equivalent SA in Filipe's projects, restricted
to the resources that this Terraform stack actually creates (VPCs,
subnets, peering, GCS objects, log entries).

#### 3.2.1. On each workload project

| Role | Purpose |
|---|---|
| `roles/compute.networkAdmin` | Create the workload VPC, subnets and the workload side of the VPC peering. |
| `roles/serviceusage.serviceUsageAdmin` | Enable the GCP APIs the stack depends on (`compute`, `iam`, `cloudresourcemanager`, etc.) via the `project_services` Terraform sub-module. |
| `roles/logging.logWriter` | Required because each Cloud Build run uses this Service Account; without it the build is rejected. |
| `roles/iam.serviceAccountUser` (granted on the Service Account itself) | Required so the Cloud Build P4SA can attach this Service Account to the build. |

> If you prefer a single broad role for simplicity, `roles/editor` covers
> all of the above except for the `iam.serviceAccountUser` self-binding.
> Filipe's existing SA uses this approach. We will follow whichever
> pattern your team prefers.

#### 3.2.2. On the Shared VPC host project

| Role | Purpose |
|---|---|
| `roles/compute.networkAdmin` | Required for the host side of the bidirectional VPC peering between the workload VPC and the shared VPC. |
| `roles/compute.xpnAdmin` *(only if the stack also attaches the workload as a Shared VPC service project)* | Manage the Shared VPC service project attachment. Otherwise this role can be omitted. |

#### 3.2.3. On the GCS buckets (see §5)

Granted at the bucket level, not at the project level:

| Role | Bucket | Purpose |
|---|---|---|
| `roles/storage.objectAdmin` | Terraform state bucket | Read and write `tfstate`. |
| `roles/storage.objectAdmin` | CIDR registry bucket | Read and update `cidr-registry.txt`. |

#### 3.2.4. Cloud Build P4SA bindings (per workload project)

For the Cloud Build service of each workload project to be able to
**invoke** the Terraform CI Service Account, the default Cloud Build
P4SA of that workload project
(`service-<PROJECT_NUMBER>@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
must be granted both of the following on the Terraform CI Service
Account:

- `roles/iam.serviceAccountUser`
- `roles/iam.serviceAccountTokenCreator`

This is the standard cross-project impersonation grant; it is identical
to what Filipe's pipeline already uses today for the existing projects.

### 3.3. Optional: organization-level constraint to confirm

If the Cross GCP organization enforces the
`iam.disableCrossProjectServiceAccountUsage` Org Policy on the workload
projects, the Cross IT team must either set it to `Not enforced` on the
workload projects (so the central SA can be reused) **or** ask us to
adapt the design so that one local Service Account is provisioned per
workload project. Both patterns are supported by our pipeline; the
Cross team chooses which one fits the organization's compliance posture.

---

## 4. GitHub repository access

The integration between Cloud Build and the Terraform repository
requires the **Cloud Build GitHub App** to be installed on your
repository, with permission to read code and write status checks.

### 4.1. What the Cross IT team installs

1. The **Cloud Build GitHub App** on the Cross Insurance GitHub
   organization, granted access to the Terraform repository
   (`<cross-org>/<terraform-repo>`). Reference:
   <https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github>.
2. Inside Cloud Build, in **each workload project**, the
   `Connect repository` action that maps the GitHub repository to that
   project. Repository connections are scoped per project, so this step
   is repeated once per workload project.

### 4.2. Why Kloudstax does not need GitHub admin

Today, when an external user attempts to install the GitHub App from
outside your organization, the GitHub UI shows a **"Request"** button
instead of "Install" — the install requires GitHub Org Admin or
Repository Admin privileges. Because the Cross IT team will perform the
installation, **no GitHub access is required for Kloudstax personnel**.

### 4.3. Repository write access

Kloudstax personnel only need standard `Write` access on the Terraform
repository (the same level required to open pull requests and merge
changes). No admin or owner role is needed.

---

## 5. Shared GCS buckets (state and CIDR registry)

The pipeline depends on two GCS buckets. The Cross Insurance team is
free to choose where they reside; we recommend creating both in the
**Shared VPC host project**.

| Bucket | Content | Expected size |
|---|---|---|
| `<state-bucket>` | Terraform state for every stack (one prefix per workload). | < 100 MB total |
| `<cidr-registry-bucket>` | The `cidr-registry.txt` plain-text file. | < 1 KB |

Recommended bucket configuration:

- **Object versioning enabled** on the state bucket (essential for
  recovery from accidental writes or corrupted state).
- **Uniform bucket-level access** enabled on both buckets.
- **Location** matching the workload region (for example `us-central1`)
  or the corresponding multi-region (`us` / `eu`).

A naming convention we suggest:

- `<host-project>-terraform-state`
- `<host-project>-vpc-cidr-validator`

If your organization already has a naming standard, please share the
final bucket names so we can configure them in `deploy.sh` and in the
`cloudbuild-*.yaml` pipelines.

---

## 6. Cloud Build triggers

For each workload project, the Cross IT team creates **one trigger pair**:

| Trigger | Event | Approval | Build config |
|---|---|---|---|
| `cross-infra-<workload>-plan-main` | Push to `main` | Not required | `cloudbuild-plan.yaml` |
| `cross-infra-<workload>-apply-main` | Manual invocation | **Required** (`require-approval`) | `cloudbuild-apply.yaml` |

Both triggers must be configured to run as the Terraform CI Service
Account from §3 (Cloud Build console field: **Service account**).

The companion document [`docs/cross-cloudbuild-setup.md`](cross-cloudbuild-setup.md)
contains the step-by-step `gcloud` commands and the equivalent
console-driven workflow.

### Approver

To approve apply runs, a Cross user must hold
`roles/cloudbuild.builds.approver` on the workload project. The build
remains in `Pending approval` state until a user with that role
explicitly approves it; only then does Cloud Build execute
`terraform apply`.

---

## 7. Optional: read-only support access for Kloudstax

To support the pipeline (debug failed plans, confirm successful applies,
diagnose IAM issues), it is helpful to grant **one Kloudstax contact**
read-only access to Cloud Build:

| Role | Scope | Purpose |
|---|---|---|
| `roles/cloudbuild.builds.viewer` | Each workload project | View build history and logs. |
| `roles/logging.viewer` | Each workload project | View Cloud Build log entries in Cloud Logging. |

Recommended grantee: `marcelo.santoro@kloudstax.com`.

These roles are **read-only** and are not strictly required for the
pipeline to work. If your team prefers to handle all observability
in-house, we can support the integration purely through screen-shares
during the initial weeks.

---

## 8. Executive summary — Request to the Cross Insurance IT team

To enable the integration, we require the following six items:

1. **Create** a least-privilege **Service Account** for the Terraform
   pipeline in a Cross-controlled project (see §3.1).
2. **Grant** the granular IAM roles listed in §3.2 to that Service
   Account, including the Cloud Build P4SA cross-project bindings
   (§3.2.4).
3. **Install** the Cloud Build GitHub App on the Cross GitHub
   organization and connect the Terraform repository to each workload
   project (see §4).
4. **Create** (or confirm) the two GCS buckets for Terraform state and
   the CIDR registry (see §5).
5. **Create** the Cloud Build triggers in each workload project, wired
   to the Service Account from §1 (see §6 and
   `docs/cross-cloudbuild-setup.md`).
6. **(Optional)** Grant read-only Cloud Build / Logging access to one
   Kloudstax contact for support purposes (see §7).

Once items 1–5 are in place, the pipeline runs end-to-end:

- A push to `main` triggers `terraform plan` automatically in every
  workload project.
- An authorised Cross user invokes the apply trigger; a second
  authorised user approves it; Cloud Build then executes
  `terraform apply` non-interactively.

Estimated effort on the Cross side, once the prerequisites are agreed:
**half a day**, primarily spent in the GCP and GitHub consoles.
Kloudstax remains available to assist throughout.
