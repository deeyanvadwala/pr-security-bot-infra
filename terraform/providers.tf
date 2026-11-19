# Shared by Kenil and Deeyan. Deployed in ONE account (Deeyan's Learner Lab).
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }

  # Bucket is created once with the CLI (step 3 in the instructions).
  backend "s3" {
    bucket       = "pr-bot-tfstate-192507631646"
    key          = "pr-security-bot/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "github_repo" {
  description = "owner/name of the test repo"
  type        = string
}

# Learner Lab: no custom IAM roles allowed, so everything uses LabRole.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "aws_caller_identity" "current" {}

# Default VPC public subnets: no NAT Gateway needed, which keeps the budget safe.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  # Stick to three common AZs so Fargate placement never lands in an unsupported one.
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}
