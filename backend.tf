# Remote state — S3 bucket + DynamoDB lock table.
# The bucket and table below must exist BEFORE `terraform init` works here.
# See STEPS.md — step 2 creates them with two aws CLI commands.
terraform {
  backend "s3" {
    bucket         = "ebotprog-terraform-state"
    key            = "week5/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
