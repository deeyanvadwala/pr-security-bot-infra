#!/usr/bin/env bash
# Deeyan: build the scanner image and push it to ECR.
# Run right after refreshing Learner Lab credentials (the ECR login token expires with them).
# Usage: ./push_image.sh <path-to-folder-with-Dockerfile>
set -euo pipefail
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_URL="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/pr-scanner"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# linux/amd64 matters on Apple Silicon Macs, Fargate task is X86_64
docker build --platform linux/amd64 -t pr-scanner "${1:-.}"
docker tag pr-scanner:latest "$REPO_URL:latest"
docker push "$REPO_URL:latest"
echo "Pushed $REPO_URL:latest"
