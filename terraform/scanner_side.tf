# ============ SCANNER SIDE (Deeyan) ============
# ECR image -> Fargate task (clone PR, run SAST) -> report in private S3

variable "use_placeholder_scanner" {
  description = "true = public Alpine echo container (lets the event side be tested before the real image is pushed)"
  type        = bool
  default     = true
}

locals {
  scanner_image = var.use_placeholder_scanner ? "public.ecr.aws/docker/library/alpine:3.20" : "${aws_ecr_repository.scanner.repository_url}:latest"
  placeholder_cmd = ["sh", "-c", "echo Scan requested for $REPO PR $PR_NUMBER at $COMMIT_SHA, report would go to $REPORT_BUCKET; sleep 10; echo placeholder done"]
}

resource "aws_ecr_repository" "scanner" {
  name                 = "pr-scanner"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}


resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = local.report_bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = local.report_bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_ecs_cluster" "scanner" {
  name = "pr-security-bot"
  setting {
    name  = "containerInsights"
    value = "disabled" # keeps cost down
  }
}

resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/ecs/pr-scanner"
  retention_in_days = 7
}

resource "aws_security_group" "scanner" {
  name        = "pr-scanner-egress-only"
  description = "No inbound, HTTPS outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "scanner" {
  family                   = "pr-scanner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # build the image with --platform linux/amd64
  }

  container_definitions = jsonencode([merge({
    name        = "scanner"
    image       = local.scanner_image
    essential   = true
    stopTimeout = 30
    environment = [{ name = "REPORT_BUCKET", value = local.report_bucket }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.scanner.name
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "scan"
      }
    }
  }, var.use_placeholder_scanner ? { command = local.placeholder_cmd } : {})])
}

output "ecr_repository_url" {
  value = aws_ecr_repository.scanner.repository_url
}

output "report_bucket" {
  value = local.report_bucket
}

output "run_task_test_command" {
  description = "Deeyan: start one scan by hand, without the webhook"
  value = join(" ", [
    "aws ecs run-task --cluster ${aws_ecs_cluster.scanner.name}",
    "--task-definition ${aws_ecs_task_definition.scanner.family} --launch-type FARGATE",
    "--network-configuration 'awsvpcConfiguration={subnets=[${data.aws_subnets.default.ids[0]}],securityGroups=[${aws_security_group.scanner.id}],assignPublicIp=ENABLED}'",
    "--overrides file://overrides.json",
  ])
}
 
# Learner Lab's service control policy denies s3:GetBucketObjectLockConfiguration,
# which the aws_s3_bucket resource needs. So the bucket is created with the CLI,
# and Terraform manages only its public access block and versioning.
locals {
  report_bucket = "pr-bot-reports-${data.aws_caller_identity.current.account_id}"
}
