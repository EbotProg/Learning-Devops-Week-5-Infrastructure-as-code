# Pipeline Notes — Terraform on GitHub Actions

Personal reference notes, not a milestone README — everything covered while
figuring out how to run Week 5/6's Terraform through a CI/CD pipeline instead
of from a laptop. Written so future-me can set this up (or explain it) without
re-deriving any of it.

---

## 1. Why a pipeline at all

Manually, the flow is: edit `.tf` files → `terraform plan` → eyeball it →
`terraform apply`, all from one laptop. A pipeline turns that into:

```
push branch → open PR → pipeline runs: fmt, validate, plan
                              ↓
                    team reviews code + plan output
                              ↓
              merge to main → pipeline runs: apply
```

What this actually buys: infrastructure changes get reviewed like code before
they touch anything real, nobody applies from a personal machine (so nobody's
laptop needs standing AWS credentials), there's a permanent audit trail in Git

- Actions logs, and every run happens on an identical, disposable machine — no
  "works on my machine" drift.

---

## 2. Vocabulary

| Term                | Meaning                                                                                                                |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Workflow            | A YAML file in `.github/workflows/` defining an automated process                                                      |
| Trigger (`on:`)     | The event that starts it — `push`, `pull_request`, manual, schedule                                                    |
| Job                 | A group of steps, runs on one machine                                                                                  |
| Runner              | The disposable VM that executes a job (e.g. `ubuntu-latest`)                                                           |
| Step                | One command (`run:`) or one reusable action (`uses:`)                                                                  |
| Secrets / Variables | Values stored in repo/environment settings, injected at runtime                                                        |
| Environment         | A named target (e.g. `dev`, `production`) — can hold its own secrets and require manual approval before a job proceeds |

**The one fact that explains half the confusing parts below:** every job gets
its own fresh runner, even two jobs in the same workflow file triggered by the
same event. Nothing on disk survives from one job to the next unless it's
explicitly passed along (artifacts) — this is _why_ artifacts, `needs:`, and
per-job credential setup all exist.

---

## 3. Problem 1 — remote state

Locally, `terraform.tfstate` sits in a folder. A fresh runner has no such
folder — without a remote backend, Terraform would think nothing exists and
try to recreate everything from scratch, colliding with what's actually there.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "my-team-tfstate-bucket"
    key          = "network/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true   # S3-native locking, Terraform >= 1.10
    # or, older/spec-required pattern: dynamodb_table = "tf-locks"
  }
}
```

**Chicken-and-egg**: Terraform can't create the bucket that stores its own
state. Create it once, by hand (or via a tiny separate one-off Terraform
config), enable versioning, block public access — before `terraform init`
ever runs against it.

If local state already exists, add the `backend` block and run
`terraform init -migrate-state` once, locally, to move it over.

---

## 4. Problem 2 — authenticating to AWS

**Option A — static access keys in GitHub Secrets.** Simple, but the
credential is long-lived: valid forever until someone manually rotates or
deletes it. If it ever leaks, whoever has it can use it indefinitely until
someone notices.

**Option B — OIDC (what to actually use).** GitHub proves its identity to AWS
with a token that expires in minutes; AWS trusts that token and hands back
credentials valid for about an hour. Nothing long-lived is stored anywhere.

### What's actually happening underneath, both ways

**Static keys:** the raw access key + secret strings get decrypted from
GitHub Secrets and dropped into the runner's environment variables on every
run. Terraform's AWS provider uses them directly to cryptographically sign
every API request (AWS's SigV4 signing). Same two strings, every single run,
forever, until manually rotated.

**OIDC, step by step:**

1. **One-time setup**: register GitHub's OIDC endpoint
   (`token.actions.githubusercontent.com`) as a trusted identity provider in
   AWS IAM.
2. Create an IAM role whose trust policy names which GitHub repo (and
   optionally branch) may use it.
3. **At runtime**, because the workflow has `id-token: write`, GitHub exposes
   an internal URL to the runner. The `configure-aws-credentials` action
   calls it and gets back a short-lived JWT — signed by GitHub, containing
   claims like "repo: org/repo, ref: refs/heads/main."
4. That action sends the JWT to AWS STS's `AssumeRoleWithWebIdentity` API,
   along with the role's ARN.
5. AWS verifies the JWT's signature against GitHub's public keys (fetched
   during setup), then checks the `aud`/`sub` claims against the role's trust
   policy conditions.
6. If it matches, STS returns **temporary** credentials — access key, secret,
   and session token — valid up to an hour.
7. Those get written into the runner's environment for the rest of the job.
   Worthless the moment the job ends or the hour expires.

### The trust policy, explained

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<REPO_NAME>:*"
        }
      }
    }
  ]
}
```

This is a **trust policy** — it says _who may become this role_, not what the
role can do once assumed (that's a separate permissions policy).

- `Principal: Federated` — the trusted party is an external identity provider
  (GitHub's OIDC endpoint), not an AWS user or another AWS service.
- `Action: sts:AssumeRoleWithWebIdentity` — the specific STS call for
  exchanging a web-identity token for real credentials (different from plain
  `sts:AssumeRole`, which is for AWS-internal principals like an EC2 role).
- `Condition → aud` — the token must have been issued _for AWS specifically_,
  not some other service GitHub's OIDC also supports.
- `Condition → sub` — the actual gatekeeper. GitHub's OIDC provider is shared
  by every repo on GitHub; without this check, **any** repo could present a
  valid GitHub token and assume this role. The pattern narrows it to one repo
  (and, with a tighter pattern like `repo:org/repo:ref:refs/heads/main`, one
  specific branch).

---

## 5. The annotated workflow — single environment, fully explained

```yaml
name: Terraform

on:
  pull_request:
    branches: [main]
    paths: ["infra/**"]
  push:
    branches: [main]
    paths: ["infra/**"]
  workflow_dispatch:

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  AWS_REGION: eu-north-1
  TF_VERSION: 1.11.0

defaults:
  run:
    working-directory: infra

jobs:
  plan:
    name: Plan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Format check
        run: terraform fmt -check -recursive

      - name: Init
        run: terraform init -input=false

      - name: Validate
        run: terraform validate

      - name: Plan
        run: terraform plan -input=false -out=tfplan
        env:
          TF_VAR_mongo_root_password: ${{ secrets.MONGO_ROOT_PASSWORD }}

      - name: Upload plan
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: infra/tfplan
          retention-days: 1

  apply:
    name: Apply
    needs: plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Init
        run: terraform init -input=false

      - name: Download plan
        uses: actions/download-artifact@v4
        with:
          name: tfplan
          path: infra

      - name: Apply
        run: terraform apply -input=false tfplan
```

### Top-level keys

- **`on:`** — three triggers: `pull_request`/`push` to `main`, both filtered
  by `paths: ["infra/**"]` (a commit that never touches that folder never
  triggers this workflow at all), plus `workflow_dispatch` for a manual
  "Run workflow" button, useful for testing without a real PR.
- **`concurrency:`** — see section 6, this is not the same job as the
  DynamoDB lock.
- **`permissions:`** — see section 7.
- **`env:`** — shared values defined once. Pinning `TF_VERSION` matters:
  without it, `setup-terraform` grabs whatever the _latest_ release is at
  run time, meaning behavior could silently shift between runs for reasons
  unrelated to your own code changes.
- **`defaults: run: working-directory: infra`** — every `run:` step in every
  job behaves as if `cd infra` ran first. Purely about where shell commands
  _execute from_ — unrelated to the `paths:` filter above, despite the
  similar-looking name.

### The `plan` job

1. `checkout@v4` — clones the repo onto the fresh runner. Must be first;
   before this the VM has no files at all.
2. `setup-terraform@v3` — installs the pinned Terraform CLI onto the runner.
3. `configure-aws-credentials@v4` — the OIDC exchange (section 4). Everything
   after this step runs _as_ the assumed IAM role.
4. `terraform fmt -check -recursive` — unlike plain `fmt` (which rewrites
   files), `-check` only reports pass/fail and exits non-zero on bad
   formatting, which fails the job — this is what makes formatting an
   actually enforced rule instead of a local nicety.
5. `terraform init -input=false` — connects to the backend, downloads
   providers. See section 9 for what `-input=false` really does.
6. `terraform validate` — syntax/consistency check, no AWS calls.
7. `terraform plan -input=false -out=tfplan` — computes the plan and saves it
   to a binary file instead of only printing it. The `env:` block injects a
   GitHub secret as `TF_VAR_mongo_root_password` — Terraform auto-maps any
   `TF_VAR_<name>` env var onto a matching `variable` block, the CI
   equivalent of a local `secrets.auto.tfvars`.
8. `upload-artifact@v4` — copies that `tfplan` file to GitHub's temporary
   run storage, tagged `tfplan`, so another job (a different machine
   entirely) can retrieve it later.

### The `apply` job

- `needs: plan` — waits for `plan` to finish successfully first.
- `if:` — only actually proceeds on a push to `main`; skipped entirely on a
  PR run (this is the actual guardrail against ever applying unreviewed
  code).
- `environment: production` — ties the job to a GitHub Environment; if that
  environment has "required reviewers" set, the job pauses right here,
  before any AWS credentials are even requested, until a human approves.
- Steps 1–3 repeat identically to `plan` — a **different runner**, nothing
  carries over except what was explicitly uploaded.
- `terraform init -input=false` — needs to run again; this fresh VM has no
  provider cache.
- `download-artifact@v4` — retrieves the exact `tfplan` file, placing it back
  on disk at `infra/tfplan`.
- `terraform apply -input=false tfplan` — see section 10: this executes the
  _saved_ plan, not a freshly computed one.

---

## 6. Concurrency vs. the DynamoDB lock — different layers, both needed

They solve different problems. **DynamoDB locking** is Terraform's own
data-safety mechanism — if two `apply` processes somehow run at the exact
same moment (two CI runs, or a CI run colliding with someone running
`apply` locally), the second is blocked before it can corrupt state. It
protects _correctness_, unconditionally, everywhere.

**`concurrency:` in the workflow** is a GitHub Actions scheduling
optimization — it stops a redundant second run from even _starting_.
Without it, two quick pushes to `main` both spin up full runners, both run
`init`/`plan` (several minutes of wasted compute), and only _then_ collide at
the DynamoDB lock — leaving one run stalled or visibly failed in the Actions
log. With it, the second run queues cleanly and starts only once the first
finishes. DynamoDB prevents corruption no matter what causes a collision;
`concurrency` prevents this _specific pipeline's_ redundant, messy collisions
from happening at all.

---

## 7. `permissions:` and `id-token: write` — what's actually being granted

**This has nothing to do with AWS permissions.** It scopes `GITHUB_TOKEN` — a
separate, auto-generated credential every workflow run gets for talking to
**GitHub's own API** (checking out code, commenting on PRs, creating
releases). By default its scope is broad; this block narrows it.

`id-token: write` specifically grants permission to **request an OIDC
identity token from GitHub** — a short-lived signed JWT proving "this is run
#X, from repo Y, branch Z." That token is not AWS access by itself; it's a
GitHub-issued identity document. What happens with it next (trading it for
real AWS credentials via `configure-aws-credentials`) is the separate step
covered in section 4. Without `id-token: write`, the workflow can't even
request that document, so the later exchange has nothing to send AWS and
fails immediately with a confusing auth error.

---

## 8. Does every job get its own runner?

Yes — every job, always, even two jobs in the same workflow file triggered by
the same push. This is the single fact that explains why artifacts exist
(section 5.8), why credentials must be re-established in every job (section
5's `apply` steps 1–3 repeat `plan`'s), and why a matrix (section 11) spins up
one full separate runner per matrix entry, all in parallel.

---

## 9. What `-input=false` actually protects against

Not "retry until input arrives" — the real scenario: if Terraform ever hits a
variable with no value and no default (say, a variable wasn't wired up
correctly in CI), its normal behavior is to _pause and interactively prompt_
— `Enter a value:` — on a machine with no human attached. Without
`-input=false`, that job doesn't fail, it just **hangs** silently until
GitHub's job timeout eventually kills it, possibly hours later, with no
useful error.

`-input=false` converts that exact scenario into an immediate, clear error
instead. If the pipeline is correctly configured (every variable has a
default or a supplied `TF_VAR_*`), this flag never changes anything in
practice — it's a safety net that only "activates" when something's
misconfigured, turning a silent multi-hour hang into a fast, debuggable
failure.

---

## 10. Does `apply` just execute what `plan` computed?

Yes, exactly, **when a saved plan file is passed as the argument**
(`terraform apply tfplan`, not bare `terraform apply`). Terraform does not
recompute a fresh diff against current AWS state — it reads the exact
serialized list of create/update/destroy actions from that binary file and
executes precisely those (beyond a basic internal check that state hasn't
moved out from under it). This is the entire point of the artifact
upload/download dance: what gets applied is provably identical to whatever a
human reviewed on the PR, not a fresh plan that merely looks similar.

**The bug to avoid**: this only works if `plan` and `apply` are part of the
_same_ workflow run. Gating `plan` to `pull_request` and `apply` to `push`
as two separately-triggered jobs means they run in two _different_ workflow
runs with no shared artifact storage — `download-artifact` finds nothing.
The fix: both jobs live in one workflow file, `plan` runs on every trigger,
`apply`'s `if:` condition restricts it to push-to-main, and `needs: plan`
sequences them within that one run.

---

## 11. Multiple environments — the matrix strategy

A matrix runs the _same_ job definition multiple times in parallel, each
time substituting a different value — one full separate runner per entry.

```yaml
jobs:
  deploy:
    strategy:
      matrix:
        region: [us-east-1, eu-west-1]
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying to ${{ matrix.region }}"
```

This spins up two runners in parallel; `${{ matrix.region }}` resolves
differently in each.

### The final workflow — dev + staging

```yaml
name: Terraform

on:
  pull_request:
    branches: [main]
    paths: ["environments/**", "modules/**"]
  push:
    branches: [main]
    paths: ["environments/**", "modules/**"]
  workflow_dispatch:

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  AWS_REGION: eu-north-1
  TF_VERSION: 1.11.0

jobs:
  plan:
    name: Plan (${{ matrix.environment }})
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, staging]
    environment: ${{ matrix.environment }}
    defaults:
      run:
        working-directory: environments/${{ matrix.environment }}
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Format check
        run: terraform fmt -check -recursive

      - name: Init
        run: terraform init -input=false

      - name: Validate
        run: terraform validate

      - name: Plan
        run: terraform plan -input=false -out=tfplan
        env:
          TF_VAR_mongo_root_password: ${{ secrets.MONGO_ROOT_PASSWORD }}
          TF_VAR_parse_master_key: ${{ secrets.PARSE_MASTER_KEY }}
          TF_VAR_dashboard_password: ${{ secrets.DASHBOARD_PASSWORD }}
          TF_VAR_bastion_allowed_ip: ${{ vars.BASTION_ALLOWED_IP }}

      - name: Upload plan
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ matrix.environment }}
          path: environments/${{ matrix.environment }}/tfplan
          retention-days: 1

  apply:
    name: Apply (${{ matrix.environment }})
    needs: plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, staging]
    environment: ${{ matrix.environment }}
    defaults:
      run:
        working-directory: environments/${{ matrix.environment }}
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Init
        run: terraform init -input=false

      - name: Download plan
        uses: actions/download-artifact@v4
        with:
          name: tfplan-${{ matrix.environment }}
          path: environments/${{ matrix.environment }}

      - name: Apply
        run: terraform apply -input=false tfplan
```

### What changed from the single-environment version, and why

- **`strategy: matrix: environment: [dev, staging]`** on both jobs — makes
  each job run twice, in parallel, as fully separate runners. Four runners
  total spin up on a push to `main`: plan-dev, plan-staging, apply-dev,
  apply-staging.
- **`environment: ${{ matrix.environment }}`** — ties each matrix instance to
  its _own_ GitHub Environment, so `secrets.MONGO_ROOT_PASSWORD` resolves to
  dev's value in the dev instance, staging's in the staging instance,
  automatically.
- **`working-directory: environments/${{ matrix.environment }}`** — points
  each instance at its real folder, which already has its own
  `backend.tf` (own state key) and `main.tf` (own `vpc_cidr` etc.) — no extra
  wiring needed on the workflow side for that part, since Terraform just
  reads whatever's sitting in that directory.
- **`name: tfplan-${{ matrix.environment }}`** on the artifact — without the
  suffix, both parallel matrix instances would try to upload an artifact
  called plain `tfplan` in the same run and collide. The suffix keeps them
  distinct; `download-artifact` in `apply` requests the exact matching name,
  so dev's `apply` downloads dev's plan, never staging's.
- **`vars.BASTION_ALLOWED_IP`** instead of `secrets.` — `vars` is for
  configuration that differs per environment but isn't actually sensitive
  (like an IP); `secrets` is reserved for genuinely sensitive values
  (encrypted, never shown in logs). Using `secrets` here wouldn't be wrong,
  just unnecessary overhead for a non-secret value.

---

## 12. Setup checklist

1. Create the S3 state bucket (versioned, private, encrypted).
2. Add the `backend "s3"` block; `terraform init -migrate-state` once if
   local state already exists.
3. Register GitHub's OIDC provider in AWS IAM; create the trust-policy role.
4. Attach a scoped permissions policy to that role (not
   `AdministratorAccess`) — only what the actual resources need.
5. Store the role ARN as a repo/environment variable (`AWS_ROLE_ARN`).
6. Create GitHub Environments (`dev`, `staging`, or `production`) with their
   own secrets/variables, and required reviewers where an approval gate is
   wanted.
7. Add the workflow file under `.github/workflows/`.
8. Turn on branch protection for `main` (require PRs + passing checks) so
   nobody bypasses the pipeline.
9. Test: open a PR with a small change, read the plan output, merge, approve
   the apply if gated, confirm it actually applied.

---

## 13. Common pitfalls

- **Secrets in `.tfvars` files** — never commit one containing a password or
  key. Pass sensitive values through GitHub Secrets as `TF_VAR_<name>`.
- **Committing `.pem` files** — reference an existing key pair by name, or
  generate it outside the repo entirely.
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`** — almost
  always a typo in the trust policy's `sub` condition (repo name is
  case-sensitive) or a missing `id-token: write`.
- **Unpinned versions** — pin both the Terraform CLI version and provider
  versions (`required_providers` with a version constraint), so a new
  release doesn't silently change behavior between runs.
- **`terraform destroy` in the automatic path** — keep it out entirely. If
  wanted at all, put it in a separate workflow gated to `workflow_dispatch`
  only, with its own approval requirement.
- **Re-planning during apply** — the single-environment example in section 5
  avoids this via the artifact hand-off; a version that skips the artifact
  and just runs `terraform apply -auto-approve` in the apply job would be
  applying a _fresh_ plan, not the one anyone reviewed.

---

## 14. Ways to improve this later

- Post the plan output as a PR comment (`pull-requests: write` is already
  granted for this) so reviewers don't have to open the Actions log.
- Add `tfsec` or `checkov` as an extra static-analysis step.
- Fetch an artifact from a _different_ prior workflow run (needed if `plan`
  and `apply` end up split across genuinely separate runs again for some
  reason) via `dawidd6/action-download-artifact` or `actions/github-script`
  — more advanced than anything covered here, worth knowing exists.
