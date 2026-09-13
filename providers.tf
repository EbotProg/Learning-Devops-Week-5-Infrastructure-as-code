# No "profile" set here on purpose — this uses whatever your default AWS CLI
# credentials/profile are (or the AWS_PROFILE env var if you set one).
# DO NOT point this at the "milestone" profile from Week 4 — that identity
# only has S3 + Budgets permissions and will fail on almost everything here.
provider "aws" {
  region = var.region
}
