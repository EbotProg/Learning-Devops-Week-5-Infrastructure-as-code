# Week 5 Study Guide — Infrastructure as Code with Terraform

Goal, per the milestone card: **never click "Launch Instance" in the console again.**
This guide covers everything listed under "Learn," gives you working code patterns
for everything under "Milestone Project," and is written against your _actual_
Month 1 infrastructure — the dual-AZ VPC, bastion pattern, and IAM setup from
Weeks 1–2 — not generic examples.

---

## 0. Before you touch any syntax: the mental model

### 0.1 What "Infrastructure as Code" actually means, and why it exists

Every week before this one, you built infrastructure by hand: clicking
"Launch Instance" in the console, filling in a VPC wizard, typing security
group rules into a form. That works, but it has a specific, recurring cost —
every time you needed the same setup again (a new environment, a rebuild
after breaking something, handing the project to someone else), you had to
either remember every click you made or redo the clicking from scratch. There
was no artifact you could hand someone that said, precisely, "this is what
exists and how it's configured."

**Infrastructure as Code (IaC)** is the practice of writing that configuration
down as a file instead — in a language a tool can read — and letting the tool
create the actual infrastructure from it. The file becomes the source of
truth: version-controlled, reviewable, and re-runnable. "Rebuild everything
from Weeks 1–2" stops meaning "remember and redo forty minutes of clicking"
and starts meaning "run one command against a file that already describes it."

Most IaC tools (Terraform included) are **declarative**: you describe the end
state you want ("this VPC should exist, with these two subnets"), not the
steps to get there. You never write "first create the VPC, then create the
subnet" — you write both as blocks, and the tool works out the order and the
API calls needed. This is the opposite of a shell script, where you _do_ have
to write the steps in the right order yourself.

### 0.2 What Terraform specifically is

Terraform is one implementation of that idea, made by HashiCorp. Concretely,
it's an engine that does three things, every time you run it:

1. **Reads your config** — the `.tf` files describing the desired state.
2. **Compares it to what it believes already exists** — tracked in the state
   file (section 6).
3. **Computes and executes the difference** — via API calls to whichever
   cloud or service your config targets.

That third point is why Terraform isn't AWS-specific, even though everything
in this guide happens to target AWS. The actual API calls are made by a
**provider** (section 2) — a plugin Terraform loads for a specific platform.
Swap the `aws` provider for `github`, `cloudflare`, or `kubernetes`, and the
exact same `resource`/`plan`/`apply` workflow manages a GitHub repo's
settings, a DNS record, or a Kubernetes deployment instead of a VPC. The
`plan` → `apply` → `destroy` workflow (section 7) is Terraform's core
contribution: it's what lets you preview _exactly_ what will change before
committing to it, which a hand-run script generally can't offer you.

Holding onto that distinction matters as you read the rest of this guide:
**Terraform is the generic engine; AWS's networking model is a separate body
of knowledge that Terraform is just describing.** The next part of this
section (0.3) is entirely AWS knowledge — none of it is Terraform-specific,
and you'd need it even if you were clicking through the console by hand. The
Terraform-specific syntax for expressing it starts at section 1.

### 0.3 The AWS mental model

Terraform's _syntax_ is genuinely simple — blocks, key-value pairs, references.
The reason implementations feel confusing when you're new to this isn't the
language. It's that every code example assumes you already have a working
mental model of _what a cloud network actually is_ and _why it's shaped the way
it is_. If you don't have that yet, `subnet_id = aws_subnet.public1.id` is just
a string being assigned to another string — you can't reason about whether it's
right. This section builds that model first, in the order things actually
depend on each other, so the code in later sections has something to hang off.

**Start with the shape of the problem.** When you "launch an instance" by hand
in the console, AWS is quietly making a dozen decisions for you — which network
it lives in, whether it's reachable from the internet, which other machines can
talk to it, what permissions it has. Terraform doesn't make those decisions;
_you_ declare all of them, explicitly, as separate resources. That's why a
Terraform config for one EC2 instance is 100+ lines instead of one `resource`
block — you're writing down every decision the console used to hide from you.
Understanding each of those decisions, in order, is the actual prerequisite.

**1. Your VPC is a private network you own inside AWS.**
Think of it as a walled-off chunk of network address space — nothing inside it
is reachable from the internet by default, and nothing inside it can reach the
internet by default either. Everything else in this section exists to
deliberately punch specific, controlled holes in that wall. The `cidr_block =
"10.0.0.0/16"` you'll see in the code isn't an arbitrary setting — it's you
choosing how large that private address space is (a /16 gives you 65,536
addresses to carve up).

**2. Subnets divide that network into zones with different exposure.**
A "public" subnet and a "private" subnet are the _same kind_ of thing — both
are just smaller address ranges carved out of the VPC's CIDR block. What makes
one "public" isn't a special AWS setting on the subnet itself; it's _what that
subnet's traffic is routed to_ (see point 3). This is why your bastion pattern
puts the bastion host in a public subnet and the app server in a private one:
you're choosing, per-machine, whether it should be directly reachable from the
internet at all.

**3. Route tables are the actual decision-maker for "public" vs "private."**
A route table is a set of rules like "traffic headed to 0.0.0.0/0 (i.e.
anywhere) goes out through _this_ gate." A subnet is "public" specifically
because its route table sends outbound traffic to an **Internet Gateway** —
a direct, two-way door to the internet. A subnet is "private" because its
route table instead sends outbound traffic to a **NAT Gateway** — a one-way
door that lets things _inside_ reach _out_ (e.g. your app server downloading a
package) but lets nothing from the internet initiate a connection _in_. This
is the single most important asymmetry in the whole setup: public subnets get
two-way access, private subnets get outbound-only access, and the difference
is entirely which gateway their route table points at.

**4. Security groups are a second, independent layer of control — per machine, not per subnet.**
Being in a private subnet already blocks unsolicited inbound traffic from the
internet. Security groups add a further, more granular rule _on top of that_:
even for traffic that's allowed to reach the machine at all, which specific
ports, protocols, and _sources_ are allowed in or out. This is where your
bastion pattern actually lives: the bastion's security group allows SSH only
from your own IP; the app server's security group allows SSH only from the
bastion's security group — not from "everywhere," not even from "the whole
VPC." That second rule is a security group _referencing another security
group_ as its source, which is exactly the kind of relationship Terraform is
good at expressing (and exactly why order-of-creation and dependency graphs,
covered in section 1, matter).

**5. IAM roles are how a _machine_ gets permissions, without ever holding a password or key.**
An IAM _user_ (like the ones you made by hand — `ebotprog-test`,
`ecr-deploy-user`) represents a person or a long-lived external identity, and
typically has credentials someone types in or stores. An IAM _role_ is
different: it's a set of permissions that something can _temporarily assume_ —
in your case, an EC2 instance assuming `ec2-repository-role` so it can pull
from a container registry without any access key ever being written to disk
on that instance. This is the cloud-native answer to "how does this server
authenticate to that other AWS service" — the answer is almost always "a role
it assumes," not "a key it was given."

**6. An AMI is a frozen snapshot of a machine's disk, used as the starting point for a new one.**
When you launch an EC2 instance, you're not configuring an empty computer from
scratch — you're booting a copy of an existing disk image (an AMI) that
already has an operating system on it. `data.aws_ami.ubuntu` in the code isn't
creating anything; it's asking AWS "what's the current Ubuntu 24.04 image ID in
this region right now," because that ID changes every time Canonical publishes
a new build and hardcoding an old one means you're silently running an
out-of-date, unpatched image.

**Put together, this is the sequence the code in section 10 actually builds:**
a VPC (the walled space) → subnets inside it (public and private zones) →
an Internet Gateway and NAT Gateway (the two doors) → route tables (which
door each subnet uses) → security groups (per-machine firewalls, one
referencing the other) → an IAM role (permissions a machine can assume) → and
finally the EC2 instances themselves, each placed into a subnet, tagged with a
security group, and optionally attached to a role. Every resource block later
in this guide is one piece of that chain — if a line of code doesn't make
sense, the fix is almost always "which of these six things is this actually
doing," not "what does this HCL syntax mean."

**One more thing worth having straight before you start:** Terraform itself
doesn't know anything about AWS, networking, or IAM. It's a generic engine for
"describe a desired state, diff it against a tracked current state, make API
calls to close the gap." Everything above — VPCs, subnets, security groups —
is AWS's model of infrastructure, which Terraform is just a lens onto (via the
`aws` provider). That's _why_ a `provider` block exists at all, and why the
same Terraform skills transfer to GitHub, Cloudflare, or Kubernetes with a
different provider plugged in: the logic in this section is AWS knowledge, the
syntax in the sections below is Terraform knowledge, and conflating the two is
usually where "I don't get what this code is doing" actually comes from.

---

## 1. HCL syntax — the basics

Terraform's language is HCL (HashiCorp Configuration Language). Everything in it
is one of a small number of building blocks:

```hcl
# A comment starts with #  (or //, or /* ... */ for multi-line)

resource "aws_instance" "bastion" {     # BLOCK TYPE, LABEL, LABEL
  ami           = "ami-0abcd1234"       # argument = value
  instance_type = "t3.micro"

  tags = {                              # a map/object value
    Name = "bastion"
  }
}
```

- **Block type** (`resource`, `provider`, `variable`, `data`, `output`, `module`,
  `terraform`) — a fixed keyword Terraform understands.
- **Labels** — identify _which_ thing this block is. `resource` blocks take two
  labels: the resource _type_ (`aws_instance` — this determines which arguments
  are valid) and a _name_ you choose (`bastion` — this is only used to refer to
  it elsewhere in your own config, it's never sent to AWS).
- **Arguments** — `key = value` pairs inside the block. Values can be strings,
  numbers, bools, lists (`["a", "b"]`), maps (`{ key = "val" }`), or expressions
  referencing other resources.
- **References** — `<resource_type>.<name>.<attribute>` reads a value out of
  another resource. This is how resources depend on each other:

```hcl
resource "aws_subnet" "public1" {
  vpc_id = aws_vpc.main.id   # references the VPC block below, by its label "main"
  ...
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}
```

Order in the file doesn't matter — Terraform builds a dependency graph from these
references and figures out the correct creation order itself. This is **implicit
dependency**; you can also force an explicit one with `depends_on = [...]` when
two resources need to be ordered but don't reference each other directly (rare,
but real — e.g., an IAM policy that must exist before a resource that assumes
it, even if nothing in the resource's arguments reference the policy directly).

---

## 2. Providers

A provider is the plugin that knows how to talk to a specific API (AWS, GitHub,
Docker, Cloudflare — hundreds exist). You declare which ones you need and which
versions, then configure them:

```hcl
# terraform.tf — pins Terraform's own version and which providers to download
terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.98"
    }
  }
}

# providers.tf — configures the AWS provider specifically
provider "aws" {
  region  = "eu-north-1"
  profile = "milestone"   # reuses the named CLI profile you already have —
                           # never hardcode access keys in a .tf file
}
```

**Never put `access_key`/`secret_key` literals in provider config.** Terraform
reads credentials the same way the AWS CLI does — from a named profile, from
environment variables, or from an instance's attached IAM role. You already have
a `milestone` profile configured from Week 4; point Terraform at it with
`profile = "milestone"` and you're done. This is the direct Terraform equivalent
of the "IAM role instead of embedded keys" lesson from Week 1.

---

## 3. Resources

A `resource` block is a declaration: "this thing should exist, with these
settings." You don't write imperative steps ("create a VPC, then create a
subnet") — you describe the end state, and Terraform works out what API calls
are needed to get there, whether that's creating something from nothing,
updating an existing resource in place, or destroying and recreating it if a
change can't be applied any other way (e.g., changing an EC2 instance's AMI
forces replacement; changing its tags does not).

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "vpc-week-2-devops-training-vpc" }
}
```

Every resource, once created, gets tracked by Terraform in the **state file**
(more on that below) — that's how Terraform knows this VPC already exists next
time you run `plan`, instead of trying to create a duplicate.

---

## 4. Data sources

A `data` block _reads_ information about something that already exists, rather
than creating anything. The most common one you'll actually need: looking up
the latest Ubuntu AMI instead of hardcoding an AMI ID (AMI IDs are
region-specific and go stale as new images are published):

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical's account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "bastion" {
  ami           = data.aws_ami.ubuntu.id   # always resolves to the current AMI
  instance_type = "t3.micro"
}
```

---

## 5. Variables and outputs

**Input variables** — parameterize your config instead of hardcoding values:

```hcl
# variables.tf
variable "region" {
  type        = string
  description = "AWS region to deploy into"
  default     = "eu-north-1"
}

variable "bastion_allowed_ip" {
  type        = string
  description = "Your IP, allowed to SSH into the bastion"
  sensitive   = false
}
```

Reference a variable anywhere with `var.region`. Provide values three ways,
in increasing order of precedence: a `default` in the variable block itself,
a `terraform.tfvars` file (auto-loaded, never commit this if it has secrets),
or `-var="region=eu-west-1"` on the command line.

**Outputs** — surface a value after `apply` finishes, for you to read or for
another piece of automation to consume:

```hcl
# outputs.tf
output "bastion_public_ip" {
  value       = aws_instance.bastion.public_ip
  description = "SSH into this address"
}
```

After `terraform apply`, this prints right in your terminal — no more digging
through the console to find the IP, which is exactly the kind of manual step
this whole milestone is about eliminating.

---

## 6. The state file

Terraform's state file (`terraform.tfstate`) is a JSON file that maps every
resource block in your config to the real-world object it created — the actual
VPC ID, instance ID, and so on. **This is the single most important concept in
Terraform to actually understand, not just know the name of:**

- Terraform has no other way of knowing what it's already created. Delete the
  state file and Terraform believes none of your infrastructure exists — the
  next `apply` will try to create everything again from scratch, likely
  colliding with what's already there.
- The state file often contains sensitive data in plaintext (an RDS password
  set via a variable, for instance) — **never commit it to git.** Add to
  `.gitignore`:
  ```
  *.tfstate
  *.tfstate.*
  .terraform/
  ```
- By default, state lives as a local file in your project folder — fine for
  solo experimentation, a real liability the moment more than one person or
  machine might run `apply` (two people running `apply` from two different
  local state files will each think they have the only copy of the truth, and
  will happily create duplicate or conflicting infrastructure).

That last point is exactly what **remote state** (section 8) solves.

---

## 7. The core workflow — init, plan, apply, destroy

```bash
terraform init      # downloads providers, sets up the backend — run this first,
                     # and again any time you add a provider or change the backend

terraform fmt        # auto-formats your .tf files to canonical style
terraform validate   # checks syntax and internal consistency, no AWS calls made

terraform plan        # shows what WOULD change, makes no changes yet
terraform apply       # shows the same plan, asks for confirmation, then executes it
terraform apply -auto-approve   # skips the confirmation prompt (use in recordings/CI)

terraform destroy     # tears down every resource this config's state knows about
```

**`plan` is your safety net — read it every time**, not just on faith. Its
output uses `+` (create), `-` (destroy), `~` (update in place), and
`-/+` (destroy and recreate) prefixes on each resource. A `-/+` you weren't
expecting is exactly the moment to stop and ask why, before typing `yes`.

`terraform output` re-prints your outputs any time, without re-running apply.

---

## 8. Remote state — S3 backend + DynamoDB locking

Per the milestone card, this is an S3 bucket for the state file itself, plus a
**DynamoDB table** as the locking mechanism, so two people (or two CI runs)
can't `apply` at the same moment and corrupt the state. This is the pattern
the milestone explicitly names, so it's what's walked through in full below.

**How the locking actually works, conceptually:** every time you run `plan`
or `apply`, Terraform first tries to write a "lock" record into the DynamoDB
table before touching the state file. If a lock record is already there
(because someone else's `apply` is mid-flight), your command fails fast with
a "state is locked" error instead of silently racing the other run and
corrupting the state file. When the run finishes, Terraform deletes its lock
record. The table doesn't store your infrastructure data at all — it's purely
a mutual-exclusion mechanism, which is why it only ever needs one row at a
time and can be tiny/cheap.

### Bootstrapping the bucket and the table

Same chicken-and-egg problem as any backend (see below): the bucket and
table that Terraform's state depends on have to exist _before_ Terraform can
be told to use them, so create both once, manually, via the CLI:

```bash
# the state bucket
aws s3api create-bucket --bucket ebotprog-terraform-state \
  --region eu-north-1 --create-bucket-configuration LocationConstraint=eu-north-1
aws s3api put-bucket-versioning --bucket ebotprog-terraform-state \
  --versioning-configuration Status=Enabled

# the DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-north-1
```

A few things worth understanding rather than just copying:

- **`AttributeName=LockID,AttributeType=S`** — the table needs exactly one
  column, named `LockID`, holding a string (`S`). This isn't a name you get
  to choose — Terraform's S3 backend expects a table with precisely this
  schema, and will fail with a schema-mismatch error if the attribute name or
  type doesn't match.
- **`--key-schema AttributeName=LockID,KeyType=HASH`** — `LockID` is the
  table's _partition key_ (DynamoDB's term for primary key on a
  single-attribute table). Every lock record is looked up and written by this
  one field.
- **`--billing-mode PAY_PER_REQUEST`** — this table gets one write and one
  delete per `apply`/`plan` run, essentially never under real load, so
  on-demand (pay only for what you use) billing is the sensible choice over
  provisioning fixed read/write capacity you'd mostly pay for and not use.

If you'd rather see this as a Terraform resource for documentation purposes
(you still create it manually first, exactly like the bucket — this is just
what the equivalent config looks like, so you can recognize it and explain the
schema if asked):

```hcl
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

### Wiring the backend to both

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "ebotprog-terraform-state"
    key            = "week5/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"   # <- this is the line that turns on DynamoDB locking
  }
}
```

`dynamodb_table` is the argument that tells the S3 backend which table to use
for locking. With it set, every `plan`/`apply`/`destroy` acquires a lock in
that table first; without it, the backend has no locking at all (pre-1.9
Terraform) or falls back to no lock (if you also don't set `use_lockfile`).

> **Worth knowing, in case it comes up in review:** this "S3 + DynamoDB" combo
> was the standard pattern for years and is exactly what the milestone card
> asks for, so it's the one built out above. As of Terraform 1.9+ (stable as
> of 1.11), S3 also supports **native locking** directly via a different
> argument, `use_lockfile = true`, with no DynamoDB table involved at all:
>
> ```hcl
> terraform {
>   backend "s3" {
>     bucket       = "ebotprog-terraform-state"
>     key          = "week5/terraform.tfstate"
>     region       = "eu-north-1"
>     encrypt      = true
>     use_lockfile = true
>   }
> }
> ```
>
> HashiCorp's own current guidance actually steers new projects toward this
> newer option, since it's one less resource to create, pay for, and keep in
> sync with the bucket. But since your milestone spec names DynamoDB
> specifically, build it the way documented above — it's still fully
> supported and correct, just no longer the _default_ recommendation for
> greenfield projects. Knowing both means you can explain the tradeoff if
> asked why the newer option exists and why you didn't use it here.

**The chicken-and-egg problem, and how to actually solve it:** the S3 bucket
that stores your state has to exist _before_ you can tell Terraform to use it
as a backend — but you'd normally create that bucket _with_ Terraform. You
can't have a config whose backend is a bucket (and table) that same config
hasn't created yet.

The standard resolution: create the state bucket and the DynamoDB table in a
small, separate, one-time step — either a tiny separate Terraform config with
purely _local_ state (that you run once and more or less never touch again),
or manually via the AWS CLI as shown above, since these are two resources
you're creating exactly once.

(Versioning on the bucket matters for a different reason than your Week 4 S3
bucket — it means if state ever gets corrupted or wrongly overwritten, you can
recover the previous version.)

Then, in your _main_ project (the one with all your real infrastructure),
add the `backend "s3"` block shown above and run:

```bash
terraform init -migrate-state
```

This moves your existing local state into the new remote backend, prompting
you to confirm — the same migration step you'd use if you started local and
moved to remote later, which is a completely normal and expected sequence, not
a workaround.

### Tearing down the bootstrap resources (bucket + lock table)

The state bucket and lock table are the one part of your setup that
`terraform destroy` never touches — they were created manually, outside your
main config, specifically to avoid the chicken-and-egg problem above.
Cleaning them up later (e.g. after the milestone is fully recorded and
graded) is a manual, three-step process too:

1. **Empty the versioned bucket first.** A plain `delete-bucket` fails on a
   bucket with versioning enabled, because old versions of
   `terraform.tfstate` are still sitting there even after the "current"
   version looks deleted:

   ```bash
   BUCKET=ebotprog-terraform-state

   VERSION_COUNT=$(aws s3api list-object-versions --bucket "$BUCKET" \
     --query 'length(Versions || `[]`)' --output text)

   if [ "$VERSION_COUNT" != "0" ]; then
     aws s3api delete-objects --bucket "$BUCKET" \
       --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
       --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
   fi

   MARKER_COUNT=$(aws s3api list-object-versions --bucket "$BUCKET" \
     --query 'length(DeleteMarkers || `[]`)' --output text)

   if [ "$MARKER_COUNT" != "0" ]; then
     aws s3api delete-objects --bucket "$BUCKET" \
       --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
       --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')"
   fi
   ```

   > **A gotcha worth knowing before you hit it:** `list-object-versions`
   > only includes a `"Versions"` (or `"DeleteMarkers"`) key in its JSON
   > output _if there's at least one_. Query directly for
   > `Versions[].{Key:Key,VersionId:VersionId}` on an already-empty bucket
   > and you get `null` back, not `[]` — and `delete-objects` requires an
   > actual list, so passing `null` as `--delete` fails with:
   >
   > ```
   > ParamValidation: Invalid type for parameter Delete.Objects, value: None,
   > type: <class 'NoneType'>, valid types: <class 'list'>, <class 'tuple'>
   > ```
   >
   > The fix is the `length(Versions || \`[]\`)`pattern above: it evaluates`Versions`if present, or falls back to an empty list literal if it's
missing, giving you a real number to branch on — so the`delete-objects`
   > call only fires when there's actually something to delete. If you hit
   > this exact error, it almost always means the bucket already had nothing
   > lingering; you can skip straight to step 2.

2. **Delete the bucket itself:**

   ```bash
   aws s3api delete-bucket --bucket ebotprog-terraform-state --region eu-north-1
   ```

3. **Delete the DynamoDB lock table:**

   ```bash
   aws dynamodb delete-table --table-name terraform-locks --region eu-north-1
   ```

**What this does _not_ touch:** your admin identity, `ebotprog-test`, and
`ecr-deploy-user` are untouched by any of this, for the same reason
`terraform destroy` never touches them either — they were never Terraform
resources in the first place, by the deliberate scope decision from section
10's `iam.tf` notes. They're not "leftover" from a destroy or a teardown in
the same sense the bucket and table are; they're permanent bootstrap
identities that sit outside this milestone's scope entirely, and there's
nothing here to clean up on their account.

---

## 9. Recommended file layout

Terraform doesn't care how you split files — everything in a directory gets
read as one config regardless of filename. Splitting by concern is purely for
human readability, but it matters a lot once a config grows past a handful of
resources:

```
terraform-infra/
├── terraform.tf          # required_providers, required_version
├── providers.tf          # provider "aws" block
├── backend.tf            # remote state config
├── variables.tf          # all variable declarations
├── outputs.tf            # all outputs
├── vpc.tf                # VPC, subnets, IGW, NAT gateway, route tables
├── security_groups.tf    # Bastion SG, App-tier SG, and their rules
├── ec2.tf                # bastion + app-tier instances
├── s3.tf                 # the Week 4 milestone bucket
├── iam.tf                # IAM roles/policies (ec2-repository-role, etc.)
└── terraform.tfvars      # your actual values — gitignored if any are sensitive
```

---

## 10. Your actual infrastructure, in Terraform — a working starting point

This maps directly onto what you built by hand in Weeks 1–2. Treat this as a
skeleton to adapt, not something to copy verbatim without reading it.

### 10.0 The one mechanic that makes all of this readable

Before going block by block, get this straight, because it's the single most
common source of "wait, where was that ID defined?" confusion: **a resource's
attributes — its `.id`, its `.arn`, and so on — don't exist anywhere in your
file. They're returned by AWS at the moment the resource is actually created,
and Terraform fills them in for you.**

Every resource block has the shape:

```hcl
resource "<TYPE>" "<LOCAL_NAME>" {
  # arguments
}
```

- `<TYPE>` (e.g. `aws_vpc`) tells Terraform what kind of AWS object to create.
- `<LOCAL_NAME>` (e.g. `main`) is a name **you invent**, purely so you can
  refer to this block elsewhere in your own config. It is never sent to AWS —
  AWS has no idea your VPC is "called" `main`.

When you run `terraform apply`, Terraform calls the AWS API to create the
real object. AWS hands back real attributes that didn't exist a second
earlier — an ID, an ARN, sometimes more. Terraform stores these in state and
lets you read them anywhere else in the config with:

```
<TYPE>.<LOCAL_NAME>.<ATTRIBUTE>
```

So `aws_vpc.main.id` means: _"the `id` attribute AWS returned when it created
the `aws_vpc` resource I locally named `main`."_ You never typed that ID
yourself, and you never will — it's an implicit output of every resource,
available as `.id` (and often other attributes like `.arn` or `.cidr_block`,
depending on the resource type). This is also how Terraform knows what order
to create things in: a reference like `vpc_id = aws_vpc.main.id` tells
Terraform "this subnet depends on that VPC," so the VPC gets created first —
automatically, from the reference, not from the order you wrote the blocks in.

Keep that in mind reading every file below: whenever you see `something.id`
or `something.name` used as a value, it's not a typo or a missing
definition — it's pointing at a block elsewhere (maybe in a different file
entirely) that will exist by the time this one needs it.

### `vpc.tf`

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "vpc-week-2-devops-training-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "vpc-week-2-devops-training-igw" }
}

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/20"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true
  tags = { Name = "vpc-week-2-devops-training-subnet-public1-eu-north-1a" }
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.128.0/20"
  availability_zone = "eu-north-1a"
  tags = { Name = "vpc-week-2-devops-training-subnet-private1-eu-north-1a" }
}

# ... public2 / private2 in eu-north-1b follow the same pattern

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public1.id   # NAT lives in a PUBLIC subnet
  tags          = { Name = "vpc-week-2-devops-training-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private1" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private1.id
}
```

**Walking through what each block above actually does:**

- **`aws_vpc.main`** — creates the network container itself: an isolated
  address space spanning `10.0.0.0/16`. `enable_dns_support` /
  `enable_dns_hostnames` let instances inside it resolve DNS and get
  hostnames. Every other resource in this file lives inside it, referenced as
  `aws_vpc.main.id`.
- **`aws_internet_gateway.main`** — attaches an internet gateway to the VPC.
  Without this, nothing inside the VPC can reach the public internet at all,
  no matter what else is configured.
- **`aws_subnet.public1` / `private1`** — each is a smaller slice of the
  VPC's address range, pinned to one availability zone (a physical AWS
  datacenter location, `eu-north-1a` here). `map_public_ip_on_launch = true`
  on the public one means any instance launched there automatically gets a
  public IP — that's what signals "public" _intent_, though the actual
  internet access comes from the route table, not this setting.
- **`aws_eip.nat`** — reserves a fixed, permanent public IP address (an
  Elastic IP) that AWS won't hand to anything else. It exists solely to be
  attached to the NAT gateway next.
- **`aws_nat_gateway.main`** — the part that trips people up: the NAT gateway
  _sits in the public subnet_, even though its whole job is serving the
  private subnet. Think of it as a translator — private-subnet resources send
  their outbound traffic to it, and because it lives in a public subnet with
  a real public IP, it forwards that traffic to the internet and relays the
  response back. Nothing from the outside can _initiate_ a connection in
  through it; traffic only flows out, then back for that same request.
- **`aws_route_table.public` / `private1`** — a route table is a list of
  rules of the form "for traffic going to X, send it via Y." `0.0.0.0/0`
  means "any destination" — i.e. the whole internet. The public table sends
  that traffic straight to the internet gateway; the private table sends it
  to the NAT gateway instead. **This is what actually makes a subnet "public"
  or "private" — not a setting on the subnet, but which route table it ends
  up wired to** (see the mental model in section 0.3, point 3).
- **`aws_route_table_association.public1` / `private1`** — creating a route
  table doesn't do anything by itself; you have to explicitly wire it to a
  subnet. This is that "plug it in" step. Skip it, and the route table exists
  but nothing uses it.

**The `# ... public2 / private2` comment** is telling you to duplicate the
subnet blocks with a different `availability_zone` (`eu-north-1b`) and
non-overlapping `cidr_block`s (e.g. `10.0.16.0/20` and `10.0.144.0/20`), plus
matching route table associations. For real high availability you'd typically
also want a second NAT gateway + EIP in that AZ, so a single AZ outage doesn't
take down all outbound private traffic — this skeleton reuses one NAT gateway
for simplicity and cost, which is a reasonable milestone-scope tradeoff to
call out explicitly if asked.

> **Where does "65,536 addresses" for a `/16` actually come from?**
> An IPv4 address is 32 bits. The `/16` in `10.0.0.0/16` says "the first 16
> bits are fixed, the remaining 16 bits can be anything" — so the number of
> addresses in the block is `2^(32 - prefix length)`. For `/16`: `32 - 16 =
16` free bits, `2^16 = 65,536`. Concretely, everything from `10.0.0.0`
> through `10.0.255.255` belongs to this VPC — `256 × 256 = 65,536` addresses.
> The subnets carve smaller pieces out of that with `/20`: `32 - 20 = 12` free
> bits, `2^12 = 4,096` addresses each. Every step down in prefix length by 4
> divides the range by `2^4 = 16` — which is exactly the `/16 → /20` jump
> above (65,536 ÷ 16 = 4,096). One practical wrinkle: AWS reserves the first 4
> and the last 1 address in every subnet for internal networking (network
> address, VPC router, DNS, future use, broadcast), so a `/20` subnet gives
> you 4,096 addresses on paper but 4,091 usable ones. Later, `/32` shows up on
> a security group rule (section below) — `32 - 32 = 0` free bits, `2^0 = 1`
> address — meaning "exactly one specific IP, no range at all."

### `security_groups.tf` — the bastion pattern, done the current-best-practice way

This is the part worth paying closest attention to: your Week 2 bastion pattern
relied on one security group referencing another as its _source_. In Terraform
with a modern AWS provider, that's `aws_vpc_security_group_ingress_rule` with
`referenced_security_group_id` — **not** an inline `ingress {}` block (inline
rules are still supported but are legacy; mixing inline and standalone rules on
the same security group causes Terraform to fight itself, so pick one style and
stay consistent):

```hcl
resource "aws_security_group" "bastion" {
  name        = "Bastion SG"
  description = "Allows ssh from only my ip address"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4          = "${var.bastion_allowed_ip}/32"
  ip_protocol        = "tcp"
  from_port          = 22
  to_port             = 22
}

resource "aws_vpc_security_group_egress_rule" "bastion_out" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol        = "tcp"
  from_port          = 22
  to_port             = 22
  cidr_ipv4          = "0.0.0.0/0"   # matches the outbound rule you added by hand
}

resource "aws_security_group" "app_tier" {
  name        = "App-tier SG"
  description = "Allows ssh only from bastion"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "app_tier_ssh_from_bastion" {
  security_group_id            = aws_security_group.app_tier.id
  referenced_security_group_id = aws_security_group.bastion.id   # the dynamic reference
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}
```

**Walking through it:** a security group (SG) is a virtual firewall attached
to instances, with separate ingress (inbound) and egress (outbound) rules.
The "bastion pattern" is the setup where one small, internet-facing instance
(the bastion / jump box) is the only thing reachable from your laptop, and
everything else (the app tier) only accepts connections _from the bastion_,
never directly from the internet.

- **`aws_security_group.bastion`** — just creates the empty firewall
  container, attached to the VPC. On its own it does nothing; no rules yet.
- **`aws_vpc_security_group_ingress_rule.bastion_ssh`** — a _separate_
  resource that attaches one rule to that SG: allow inbound TCP on port 22
  (SSH) from `cidr_ipv4`. `var.bastion_allowed_ip` is an input variable
  (section 5) you'd define in `variables.tf` so your own IP isn't hardcoded
  here — you can change it later without touching this file at all.
- **`aws_vpc_security_group_egress_rule.bastion_out`** — same idea, but for
  outbound: this lets the bastion send traffic anywhere (`0.0.0.0/0`).
- **Why standalone rule resources instead of an inline `ingress {}` block
  inside `aws_security_group`?** Older Terraform code nests rules directly in
  the SG block. That style still works, but current AWS-provider guidance
  favors the standalone `aws_vpc_security_group_ingress_rule` /
  `..._egress_rule` resources, because each rule can then be created,
  changed, or destroyed independently rather than forcing a rewrite of the
  entire SG every time one rule changes. This is exactly the "pick one style,
  don't mix them" warning from earlier in this guide.
- **`aws_security_group.app_tier` and its ingress rule** — this is the actual
  chained bastion pattern. Instead of allowing SSH from an IP range,
  `referenced_security_group_id` says "allow SSH from any instance that
  belongs to the bastion security group" — regardless of what IP that
  instance happens to have. This is the dynamic, Terraform-native version of
  pointing one SG at another as its allowed source, which you did by hand in
  Week 2.

### `ec2.tf`

```hcl
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public1.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = "my-free-key-for-devops-training-server"

  tags = { Name = "bastion" }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private1.id
  vpc_security_group_ids = [aws_security_group.app_tier.id]
  key_name               = "my-free-key-for-devops-training-server"

  tags = { Name = "app-tier" }
}
```

**Walking through the key parts of each instance:**

- **`ami = data.aws_ami.ubuntu.id`** — which OS image to boot from.
  `data.aws_ami.ubuntu` is a **data source**, not a resource (section 4) — it
  doesn't create anything, it just looks up an existing AMI ID that already
  exists in AWS, using the `filter`/`owners` block shown in section 4. Note
  the syntax difference even though it looks similar to a resource reference:
  `data.<TYPE>.<NAME>.<ATTR>` reads something that already exists, rather
  than something this config is creating.
- **`subnet_id`** — `bastion` goes in `public1` because it needs to be
  internet-reachable; `app` goes in `private1` because it shouldn't be.
- **`vpc_security_group_ids`** — a _list_ (note the `[ ]`) of SG IDs to
  attach. `bastion` gets only the bastion SG; `app` gets only the app-tier
  SG — so `app` is reachable via SSH only through whatever the app-tier SG's
  ingress rule allows, which (from the file above) is "from the bastion SG,"
  matching the pattern end to end.
- **`key_name`** — references an existing SSH key pair name in AWS. This has
  to already exist, either created by hand in the console or via a matching
  `aws_key_pair` resource elsewhere in the config, so you can actually SSH in
  once the instance is up.

### `iam.tf` — one deliberate scope decision

Terraform-ifying your _IAM users_ (`ebotprog-test`, `ecr-deploy-user`) is a
judgment call worth making explicitly rather than by accident: these are the
identities that _run_ Terraform and the AWS CLI in the first place. A common,
sensible pattern is to keep the small number of bootstrap/human-operator IAM
users **out** of Terraform entirely (created once by hand, as you already did),
and only terraform-ify the roles and policies that resources _assume_ at
runtime — like `ec2-repository-role`, which nothing about its own creation
depends on Terraform's own credentials already existing:

```hcl
resource "aws_iam_role" "ec2_repository_role" {
  name = "ec2-repository-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_access" {
  role       = aws_iam_role.ec2_repository_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_instance_profile" "ec2_repository_profile" {
  name = "ec2-repository-role"
  role = aws_iam_role.ec2_repository_role.name
}
```

Attach it to an instance with `iam_instance_profile = aws_iam_instance_profile.ec2_repository_profile.name`
on the relevant `aws_instance` block.

**Walking through it:** IAM (Identity and Access Management) controls who —
or what — can do what in AWS. There's a real distinction between an IAM
**user** (a person, or a long-lived external credential) and an IAM **role**
(a set of permissions something can _temporarily assume_ — most commonly used
by AWS services themselves, like EC2, rather than by humans).

- **`aws_iam_role.ec2_repository_role`** — creates the role and defines its
  _trust policy_ (`assume_role_policy`): who is allowed to become this role
  in the first place. `Principal = { Service = "ec2.amazonaws.com" }` means
  only the EC2 service can assume it — i.e. it can be attached to EC2
  instances, not handed to an arbitrary IAM user. `jsonencode({...})`
  converts a Terraform map into a JSON string, because IAM policies are
  natively JSON documents — this pattern gets you HCL's syntax checking
  instead of hand-writing raw JSON as a literal string.
- **`aws_iam_role_policy_attachment.ecr_access`** — a role by itself has no
  permissions; it's just an identity. This attaches an actual permission
  policy, here an AWS-managed one (identified by its ARN — Amazon Resource
  Name, AWS's globally unique identifier format) that grants full access to
  ECR (Elastic Container Registry, for pulling/pushing Docker images).
- **`aws_iam_instance_profile.ec2_repository_profile`** — a quirk of AWS: EC2
  instances can't have a role attached directly. They need an _instance
  profile_, a thin wrapper around exactly one role, that exists specifically
  so EC2 can attach it. This resource creates that wrapper; the
  `iam_instance_profile` line on an `aws_instance` block is what actually
  plugs it in, letting that instance assume the role's permissions (e.g.
  pulling images from ECR) without any hardcoded AWS credentials living on
  the box itself.

**Why the human IAM users are deliberately left out of this file:**
`ebotprog-test` and `ecr-deploy-user` are the credentials you use to _run_
Terraform and the AWS CLI in the first place. If Terraform tried to manage
the very identity it's authenticating as, you can hit real chicken-and-egg
problems — Terraform accidentally revoking its own permissions mid-`apply`,
or needing those users to already exist before Terraform can even run. The
fix is the scope decision already made in this file: keep those
bootstrapped-by-hand, and only let Terraform manage downstream things — like
this EC2 role — that don't affect Terraform's own ability to authenticate.

### `s3.tf` — your Week 4 bucket

```hcl
resource "aws_s3_bucket" "milestone" {
  bucket = "devops-milestone-bucket"
}

resource "aws_s3_bucket_versioning" "milestone" {
  bucket = aws_s3_bucket.milestone.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "milestone" {
  bucket = aws_s3_bucket.milestone.id
  rule {
    id     = "ExpireOldLogs"
    status = "Enabled"
    filter { prefix = "logs/" }
    expiration { days = 30 }
  }
}

resource "aws_s3_bucket_website_configuration" "milestone" {
  bucket = aws_s3_bucket.milestone.id
  index_document { suffix = "index.html" }
}
```

**Walking through it:**

- **`aws_s3_bucket.milestone`** — creates the bucket (object storage
  container). The `bucket` argument is the _actual_ desired bucket name —
  S3 bucket names are globally unique across every AWS account on the
  planet, so if `devops-milestone-bucket` is already taken by someone else's
  account, this will fail and you'll need a different name.
- **`aws_s3_bucket_versioning.milestone`** — a separate resource that turns
  on versioning: every time an object is overwritten or deleted, S3 keeps the
  old version instead of discarding it, so you can recover a previous copy.
  Notice the pattern here — bucket-level features (versioning, lifecycle,
  website hosting) are each their _own_ resource block, pointing back at the
  bucket via `aws_s3_bucket.milestone.id`, rather than being nested inline
  inside the `aws_s3_bucket` block itself (that inline style is the older,
  now-deprecated approach — same "standalone resources over inline blocks"
  pattern you saw with security group rules).
- **`aws_s3_bucket_lifecycle_configuration.milestone`** — automatically
  deletes objects based on age, so storage cost doesn't grow forever. This
  rule says: anything whose key (path/filename) starts with `logs/` gets
  deleted 30 days after creation. `filter { prefix = "logs/" }` scopes the
  rule to just that "folder" — S3 doesn't have real folders, just prefixes in
  object keys that display like folder paths.
- **`aws_s3_bucket_website_configuration.milestone`** — turns the bucket into
  a static website host; S3 can serve files directly over HTTP with no web
  server involved. `index_document { suffix = "index.html" }` tells S3 which
  file to serve when a "directory" path is requested (e.g. `/` or `/about/`
  serves `about/index.html`). This resource alone doesn't make the bucket
  publicly reachable, though — you'd typically also need a bucket policy or
  public-access-block settings to actually expose it to the internet; this
  just configures the website _behavior_ once it is exposed.

**One thing worth flagging before you run any of this:** the files above
reference `var.bastion_allowed_ip` and `data.aws_ami.ubuntu`, and neither is
fully defined in the code samples in this guide by itself. You need both,
somewhere in your project:

```hcl
# variables.tf
variable "bastion_allowed_ip" {
  type        = string
  description = "Your IP address, allowed to SSH into the bastion"
}
```

```hcl
# data.tf (or alongside ec2.tf)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical's account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}
```

Run `terraform plan` without these declared and you'll get a
"reference to undeclared resource/variable" error — that error is Terraform
telling you exactly this: something in your config points at a name that
doesn't exist anywhere in the files it read.

---

## 11. How to actually run the milestone

1. **Don't try to `import` your existing hand-built resources.** The milestone
   explicitly wants a `destroy` → `apply` → live-again demonstration, which is
   a much cleaner story than reconciling imported state against hand-written
   config. Tear down what you built manually (you already know how — you've
   done this exact teardown/rebuild cycle multiple times this course), write
   the Terraform config fresh against an empty account, and let `apply` build
   it all from nothing.
2. Bootstrap the state bucket manually (section 8), once.
3. Write the config, split across files as in section 9.
4. `terraform init`, `terraform fmt`, `terraform validate`.
5. `terraform plan` — read it. Every resource should show as `+ create`, nothing
   unexpected.
6. `terraform apply`.
7. Verify the app is actually reachable — same checks you've been doing all
   course (`docker ps`, hitting the site in a browser).
8. **Record the actual milestone proof**: `terraform destroy` (confirm
   everything disappears — check the console if you want extra confidence),
   then `terraform apply` again from a clean slate, then confirm the site is
   live again. Time this — the milestone specifically wants "within minutes,"
   which is the entire point of the exercise: this used to take you an evening
   of manual clicking, and now it's one command and a coffee break.

---

## 12. Common pitfalls, worth knowing before you hit them

- **Committing `.terraform/` or `*.tfstate` to git.** Both contain
  account-specific data and potentially secrets. Gitignore both from the start.
- **Two security groups referencing each other in opposite directions** —
  not your case here (only App-tier → Bastion, one direction), but worth
  knowing: if two security groups ever need to reference _each other_, you'll
  hit a genuine circular dependency Terraform can't resolve at creation, since
  you can't reference a resource's ID before it exists. Fixed by creating both
  security groups with no rules first, then adding the rules as separate
  resources afterward, once both IDs exist.
- **`terraform destroy` deletes _everything currently in state_ for that
  config** — including things you might not want gone if you scoped your
  config more broadly than you meant to. `terraform destroy -target=<resource>`
  exists for a scalpel instead of the whole config, but reach for it rarely —
  target-based operations that become habitual are usually a sign the config
  should be split into smaller, independent state files instead.
- **Hardcoded AMI IDs going stale** — use the `data "aws_ami"` lookup pattern
  from section 4, not a literal `ami-0abcd1234` you copied from the console
  once.

---

## Deliverables checklist, mapped to the milestone card

- [ ] Terraform repo, organized into logical files (section 9)
- [ ] VPC, subnets, IGW, NAT, route tables, security groups, EC2, S3, IAM — all
      as Terraform resources (section 10)
- [ ] Remote backend configured — S3 bucket + DynamoDB lock table, per the
      milestone card and section 8
- [ ] README with real `plan`/`apply` output pasted in (not paraphrased —
      actual terminal output, redacting your account ID same as every other
      week)
- [ ] A recording of `destroy` → `apply` → confirming the live site again
