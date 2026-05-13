# Cross Insurance — Access Requirements for the Cloud Build Integration

> Document prepared for the **Cross Insurance** IT team. It enumerates the
> GCP and GitHub access we require in order to deploy, in your environment,
> the Terraform / Cloud Build pipeline (automatic plan on `main`, manual
> apply with mandatory approval) currently running in our internal sandbox
> (`ks-crossinsurance-proj-test-01..04`).

---

## TL;DR — Summary of required actions

| # | Action | Scope | Granted by |
|---|---|---|---|
| 1 | Provide a GCP user account for `marcelo.santoro@kloudstax.com`, granted **`roles/owner`** (or the equivalent set of granular roles described in §2) on the workload projects (`<workload-prod>`, `<workload-stg>`, `<workload-dev>`) and on the Shared VPC host project. | Cross GCP Organization | Org Admin / Project Owner |
| 2 | Decide on the **Terraform execution Service Account** strategy: reuse a single central SA across projects (Option A) or provision one local SA per workload project (Option B). See §4. | Cross GCP | Cross IT team |
| 3 | If Option A is chosen, set the **Organization Policy** `iam.disableCrossProjectServiceAccountUsage` to `Not enforced` on the workload projects. See §5. | Cross GCP Org / Project | Organization Policy Administrator |
| 4 | Either install the **Cloud Build GitHub App** on the Terraform repository, or grant **repository Admin** rights to `msantoroks` (or an equivalent Kloudstax user) so we can install the App ourselves. See §3. | Cross GitHub Organization | GitHub Org Admin / Repo Admin |
| 5 | Confirm (or authorize creation of) the GCS buckets that will host the **Terraform remote state** and the **central CIDR registry**. See §6. | Cross GCP | Cross IT team |

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
access detailed in the following sections.

---

## 2. GCP access in the Cross Insurance organization

### 2.1. Kloudstax users

Please invite the following user to the relevant Cross Insurance
projects:

- `marcelo.santoro@kloudstax.com`

With **one** of the following privilege levels (in order of preference):

1. **`roles/owner`** on each workload project (`<workload-prod>`,
   `<workload-stg>`, `<workload-dev>`) and on the Shared VPC host
   project.
   - This covers every operation required during integration and is the
     fastest path to delivery.

2. **OR** the granular combination listed below, if Owner is not
   acceptable in your environment:

   | Role | Scope | Purpose |
   |---|---|---|
   | `roles/cloudbuild.builds.editor` | each workload project | Create and edit triggers; run builds. |
   | `roles/cloudbuild.connectionAdmin` | each workload project | Connect the GitHub repository to Cloud Build. |
   | `roles/iam.serviceAccountAdmin` | each workload project + host | Create local Service Accounts (Option B). |
   | `roles/iam.serviceAccountUser` | on the Terraform Service Account | Use the SA when creating triggers. |
   | `roles/resourcemanager.projectIamAdmin` | each workload project + host | Manage IAM bindings. |
   | `roles/orgpolicy.policyAdmin` | organization or project level | Adjust the org policy described in §5. |
   | `roles/storage.admin` | host project | Create and configure the state and CIDR registry buckets. |
   | `roles/compute.networkAdmin` | host project | Validate the Shared VPC and configure peering. |

> Recommendation: grant `Owner` during the integration phase and
> downgrade to the granular set above once the pipeline is operational.

### 2.2. Terraform Service Account access

See §4. The required permissions depend on which option is selected.

---

## 3. GitHub repository access

The integration between Cloud Build and the Terraform repository requires
the **Cloud Build GitHub App** to be installed on your repository, with
permission to read code and write status checks.

When attempting to connect the repository today from the Cross Insurance
Cloud Build console, the action button is displayed as **"Request"**
(rather than "Connect"). This is caused by one of two situations:

1. The user attempting the connection (`msantoroks`) is **not a
   repository administrator** in the Cross GitHub organization.
2. **OR** the GitHub App is not installed in the organization, and
   installation requires Org Owner or Repository Admin privileges.

### Required action

**Option A (preferred).** The Cross IT team installs the **Cloud Build
GitHub App** in the GitHub organization and grants it access to the
Terraform repository (`<cross-org>/<terraform-repo>`).
Reference: https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github

**Option B.** Grant **Admin** rights on the repository to `msantoroks`,
strictly for the duration of the integration. The role can be revoked
once all triggers are configured.

Without one of these two options the Cloud Build service cannot receive
push webhooks, and the plan/apply pipeline cannot operate.

### Once the GitHub App is installed

For each of the N workload projects (`prod`, `stg`, `dev`, etc.) the
**`Connect repository`** action must be repeated inside that specific
project — repository connections in Cloud Build are scoped per project,
not per organization.

---

## 4. Terraform execution Service Account

Two strategies are possible. **Decision to be made jointly by Kloudstax
and Cross Insurance.**

### Option A — Reuse the central Service Account already in place

A central Service Account is already in use in your environment for the
Cloud Build pipelines that Filipe configured for the existing projects:
something along the lines of
`<sa-terraform-ci-cross>@<cross-terraform-project>.iam.gserviceaccount.com`.

**Advantages.** A single identity audits all Terraform executions across
all workload projects. Permissions are granted in a single location and
can be reviewed centrally.

**Prerequisite.** The SA must be allowed to be impersonated across
projects. The Org Policy `iam.disableCrossProjectServiceAccountUsage`
must therefore be set to **`Not enforced`** on the workload projects.
See §5.

**Required permissions for this Service Account:**

| Role | Scope | Purpose |
|---|---|---|
| `roles/editor` (or equivalent granular network/compute roles) | Each workload project | Create VPCs, subnets and peering resources. |
| `roles/logging.logWriter` | Each workload project | Required for Cloud Build runs that use a custom Service Account. |
| `roles/compute.networkAdmin` | Host project (Shared VPC) | Configure bidirectional VPC peering between the workload and the host. |
| `roles/storage.objectAdmin` | State bucket | Read and write `tfstate`. |
| `roles/storage.objectAdmin` | CIDR registry bucket | Read and update `cidr-registry.txt`. |
| `roles/iam.serviceAccountUser` (granted to the Kloudstax users on the SA itself) | n/a | Allow the users to attach the SA to the triggers they create. |

In addition, in order for the Cloud Build service of each workload
project to **invoke** the central Service Account, the default Cloud
Build P4SA of that workload project
(`service-<PROJECT_NUMBER>@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
must be granted both `roles/iam.serviceAccountUser` and
`roles/iam.serviceAccountTokenCreator` on the central SA.

### Option B — One local Service Account per workload project (fallback)

If the Org Policy in §5 is enforced and cannot be relaxed, we provision
**one Service Account per workload project**, named
`sa-terraform-ci@<workload-N>.iam.gserviceaccount.com`.

**Advantages.** Avoids the cross-project impersonation requirement
entirely. Operates regardless of the value of
`iam.disableCrossProjectServiceAccountUsage`.

**Disadvantages.** N Service Accounts to maintain and audit. Each one
must receive the same set of permissions described in Option A, minus the
cross-project impersonation grants.

> In our internal test environment we ultimately adopted **Option B**,
> because the Kloudstax organization enforces this policy. If the same is
> true for the Cross Insurance organization, Option A will not be
> available on day one.

---

## 5. Organization Policy: `iam.disableCrossProjectServiceAccountUsage`

If Option A is selected (central cross-project Service Account), this
policy must be set to **`Not enforced`** on the workload projects.

### How to verify the current state

```bash
gcloud org-policies describe \
  iam.disableCrossProjectServiceAccountUsage \
  --project=<workload-N>
```

If the output shows `enforced: true`, or `inheritedFrom: ...` together
with `enforced`, the policy is currently blocking cross-project
impersonation.

### How to disable (requires Organization Policy Administrator)

At **project level** (recommended when the organization-wide policy
cannot be modified):

```bash
gcloud org-policies reset \
  iam.disableCrossProjectServiceAccountUsage \
  --project=<workload-N>
```

Or, more explicitly:

```bash
cat <<EOF > policy.yaml
name: projects/<workload-N>/policies/iam.disableCrossProjectServiceAccountUsage
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy policy.yaml
```

The action must be repeated for each workload project.

### Hardening note

Even with the policy set to `Not enforced`, we recommend restricting the
ability to impersonate the central Service Account (via
`roles/iam.serviceAccountUser`) to:

- The human users responsible for creating triggers (Kloudstax personnel
  and Cross Insurance designated owners).
- The default Cloud Build Service Account of each workload project
  (which executes the build at runtime).

---

## 6. Shared GCS buckets (state and CIDR registry)

The pipeline depends on two GCS buckets. The Cross Insurance team is free
to choose where they reside:

| Bucket | Content | Expected size |
|---|---|---|
| `<state-bucket>` | Terraform state for every stack (one prefix per workload) | < 100 MB total |
| `<cidr-registry-bucket>` | The `cidr-registry.txt` plain-text file | < 1 KB |

We recommend creating both in the **host** project (the one that owns
the Shared VPC), with the following configuration:

- **Object versioning enabled** on the state bucket (essential for
  recovery from accidental writes).
- **Uniform bucket-level access** enabled.
- **Location** matching the workload region (for example `us-central1`)
  or the corresponding multi-region (`us` / `eu`).

A naming convention we suggest:

- `<host-project>-terraform-state`
- `<host-project>-vpc-cidr-validator`

If your organization already maintains its own naming convention, please
share the bucket names so we can configure them in `deploy.sh` and in the
`cloudbuild-*.yaml` files.

---

## 7. Executive summary — Request to the Cross Insurance IT team

To enable the integration, we require the following six items:

1. **Invite** `marcelo.santoro@kloudstax.com` to the relevant GCP projects
   with `Owner` for the duration of the setup phase (downgrade to
   granular roles afterwards — see §2.1).
2. **Decide** between Option A (central cross-project SA) and Option B
   (one local SA per workload project). Option A is preferred provided
   the Org Policy in §5 allows it; Option B otherwise.
3. If Option A is chosen, **ensure** that
   `iam.disableCrossProjectServiceAccountUsage` is `Not enforced` on the
   workload projects (see §5).
4. **Install the Cloud Build GitHub App** on the Terraform repository,
   **or** grant repository Admin to `msantoroks` so that we can perform
   the installation ourselves (see §3).
5. **Confirm the names and locations of the GCS buckets** for state and
   CIDR registry (see §6), or authorize us to create them.
6. **Confirm the project IDs** of the workload projects and of the
   Shared VPC host project that the pipeline will target, together with
   the CIDR blocks intended for each VPC.

Once these six items are in place, we will be able to:

- Connect the repository to all N workload projects.
- Provision or reuse the Terraform Service Account as agreed.
- Create the triggers (one plan + one apply per project, totalling 2N
  triggers).
- Execute the first end-to-end `plan` and demonstrate a manually
  approved `apply`.

Estimated effort once the six items above are delivered: **half a day**
of work on our side.
