# `organization/` apply runbook

`organization/` is **never applied by CI** — and that's deliberate. `TerraformDeploy`
(the role CI's apply job assumes) has no `organizations:*`, `account:*`, or SCP
permissions, and there is no GitHub-OIDC-assumable role anywhere that does. AWS
Organizations administration — account creation, OU structure, SCPs, the org
CloudTrail — is applied by a human from the management account, per AWS's guidance
to keep the management account's automation least-privilege.

What CI *does* do for `organization/`:

- **Plan on every PR** (`Plan (organization)` in `.github/workflows/terraform.yaml`),
  posted as a PR comment.
- **Stamp and attest that plan.** The plan job writes `tfplan.sha` (the PR head
  commit), `tfplan.sha256` (checksum of the binary + the stamp), and an
  `actions/attest-build-provenance` attestation, then uploads all of it as the
  `tfplan-organization` artifact (30-day retention).
- **Refresh-only drift plan nightly** (`drift-detection.yaml`).

This runbook is how you turn that reviewed, attested plan into an apply **without**
re-planning on your laptop — so what lands in AWS is exactly what was reviewed on
the PR, not whatever your working copy happened to contain.

---

## Normal path — apply the reviewed plan artifact

### 1. Merge the PR

Wait for `Plan (organization)` to be green and the plan comment to be reviewed and
approved. Merge.

### 2. Download the reviewed plan

From a clean checkout of `main` at the merge commit:

```bash
cd organization

# Find the plan run for the PR you just merged (adjust the branch name):
gh run list --workflow terraform.yaml --branch <pr-branch-name> --limit 5

# Download the artifact from that run:
gh run download <run-id> -n tfplan-organization
# -> tfplan.binary, tfplan.sha, tfplan.sha256
```

If `gh run download` won't scope to the file, grab `tfplan-organization` from the
PR's checks UI (Artifacts section) instead.

### 3. Verify it before you trust it

```bash
# a. checksum — binary and stamp are intact and belong together
sha256sum -c tfplan.sha256

# b. commit stamp — the plan was computed from the code that actually merged
MERGED_SHA=$(gh pr view <pr-number> --json headRefOid -q .headRefOid)
[ "$(cat tfplan.sha)" = "$MERGED_SHA" ] && echo "commit stamp OK" || echo "MISMATCH — STOP"

# c. provenance — the artifact came from this repo's plan workflow, not somewhere else
gh attestation verify tfplan.binary --repo BernardoJose90/Terraform-Org
```

All three must pass. If any fails, **do not apply** — treat it as a supply-chain
signal, not a nuisance. Open a fresh PR so a new plan is produced.

### 4. Apply the file

```bash
aws sso login   # management account, admin / break-glass identity

terraform init -lockfile=readonly   # backend: s3://james-terraform-state-2026/org/terraform.tfstate
terraform apply tfplan.binary       # the FILE — no bare `terraform apply`, no fresh plan
```

Use the Terraform version pinned in `.terraform-version` at the repo root (the
single source CI reads too). AWS provider `~> 6.0` (lockfile pins 6.62.0).

If Terraform rejects the saved plan (`Saved plan is stale` / `Error: Saved plan is
outdated`), state moved since CI planned it. **Stop.** Don't `-refresh` or re-plan
around it — open a fresh PR, get a new reviewed plan, start over.

### 5. Record what you applied

Paste into the merged PR:

- the `tfplan.sha` value (the commit applied),
- who applied it and when,
- the tail of the apply output (the `Apply complete!` line + resource counts).

This is the audit trail the CI apply path gets for free and the manual path
otherwise doesn't.

---

## Fallback path — no reviewed artifact

Only for: first-time setup, an artifact that expired (>30 days), or a deliberate
out-of-band change. This path has **no reviewed-plan guarantee** — use it
knowingly.

You need the member-account root emails locally for this path — they're not in
`terraform.tfvars` (which holds no secrets). Put them in
`organization/secrets.auto.tfvars` (gitignored via `*.auto.tfvars`), matching the
`account_emails` object in `variables.tf`, or `export TF_VAR_account_emails='{...}'`
with the same JSON as the `ACCOUNT_EMAILS_JSON` secret.

```bash
cd organization
aws sso login
terraform init -lockfile=readonly   # provider versions come from the committed .terraform.lock.hcl, same as CI

# First-time only: import the pre-existing Organization (see README).
# terraform import aws_organizations_organization.aws_Org <root-id>

terraform plan -out=tfplan.binary    # review this output line by line
terraform apply tfplan.binary
```

Then record the same details in whatever PR or issue tracks the change, plus a
note that this went through the fallback path and why.

---

## Reconciling computed-attribute drift (state-only)

`drift-detection.yaml` will go red with `Objects have changed outside of Terraform`
in two situations that are **not** real drift and need no infrastructure change:

- **Just after creating a resource stack that splits settings across sibling
  resources** — e.g. `aws_s3_bucket` plus `aws_s3_bucket_versioning` /
  `_server_side_encryption_configuration` / `_policy` / `_logging` /
  `_lifecycle_configuration`, or `aws_iam_role` plus `aws_iam_role_policy`.
  Terraform records the parent's state at creation, before the siblings apply,
  and never re-reads it. The parent's now-read-only computed attributes
  (`policy`, `versioning`, `inline_policy`, …) then show as "changed" on the
  next refresh. Maintainers treat this as expected
  (hashicorp/terraform-provider-aws#24254). The normal apply path here uses a
  saved plan file, which never refreshes, so nothing closes this window on its
  own.
- **After an AWS provider major-version bump** — the first refresh surfaces
  schema/representation changes (e.g. `+ tags = {}`). HashiCorp's v6 upgrade
  guide explicitly says to run `terraform apply -refresh-only` afterwards.

Fix, run once from the management account:

```bash
cd organization
aws sso login
terraform init -lockfile=readonly
terraform apply -refresh-only
```

**Before typing `yes`, confirm the plan is state-only:** it must end with
`Plan: 0 to add, 0 to change, 0 to destroy.` and show only a `Note: Objects have
changed outside of Terraform` block — no `will be created` / `destroyed` /
`updated in-place`. `terraform apply -refresh-only` cannot modify AWS; it only
rewrites `s3://james-terraform-state-2026/org/terraform.tfstate` to match what is
already there.

If the plan shows any real create/update/destroy, **stop** — that is not this
case; treat it as genuine drift and investigate.

Record in the PR/issue that tracks the triggering change: what you ran, when, and
the `0 added, 0 changed, 0 destroyed` result. Then re-run `drift-detection.yaml`
(`gh workflow run drift-detection.yaml`) to confirm it is green.

---

## SCP safety check

Before applying anything that touches `scp.tf`:

- Read the diff for `Deny` statements and region / service restrictions.
- Confirm the management account or your break-glass role is exempt — an SCP that
  denies `iam:*` or restricts regions org-wide with no carve-out can lock every
  identity, including the one running this apply, out of making the next change.
- SCPs attach to the root or an OU. Double-check the target: a policy meant for
  the `Workloads` OU attached at the root hits the management account too.

`aws_organizations_policy` changes take effect immediately on apply — there is no
staged rollout. If in doubt, attach a new SCP to a single test OU first.
