"""PR Security Bot - webhook Lambda (event side).

API Gateway (HTTP API, payload v2) -> this Lambda.
1. Verifies GitHub's HMAC-SHA256 signature using the secret in Secrets Manager.
2. Ignores everything except pull_request opened / synchronize / reopened.
3. Marks the commit "pending" on GitHub and starts one Fargate scan task per PR event.
"""
import base64
import hashlib
import hmac
import json
import os
import urllib.request

import boto3

sm = boto3.client("secretsmanager")
ecs = boto3.client("ecs")

SCAN_ACTIONS = {"opened", "synchronize", "reopened"}
_secrets = None


def log(**fields):
    # One JSON line per decision, easy to read and filter in CloudWatch Logs.
    print(json.dumps(fields))


def get_secrets():
    global _secrets
    if _secrets is None:
        raw = sm.get_secret_value(SecretId=os.environ["SECRET_ID"])["SecretString"]
        _secrets = json.loads(raw)
    return _secrets


def signature_ok(body: bytes, header: str, secret: str) -> bool:
    if not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def set_commit_status(repo, sha, state, description, token):
    """Shows up as a check on the PR. Failure here never blocks the scan."""
    if not token:
        return
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/statuses/{sha}",
        data=json.dumps({"state": state, "description": description,
                         "context": "pr-security-bot"}).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json",
                 "User-Agent": "pr-security-bot"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:  # noqa: BLE001
        log(result="status_update_failed", error=str(e))


def reply(code, message, **extra):
    return {"statusCode": code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": message, **extra})}


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    raw = base64.b64decode(body) if event.get("isBase64Encoded") else body.encode()
    delivery = headers.get("x-github-delivery", "unknown")
    secrets = get_secrets()

    if not signature_ok(raw, headers.get("x-hub-signature-256"), secrets["webhook_secret"]):
        log(result="rejected", reason="invalid_signature", delivery=delivery)
        return reply(401, "invalid signature")

    gh_event = headers.get("x-github-event")
    if gh_event == "ping":
        log(result="ping", delivery=delivery)
        return reply(200, "pong")

    payload = json.loads(raw)
    action = payload.get("action")
    if gh_event != "pull_request" or action not in SCAN_ACTIONS:
        log(result="ignored", event=gh_event, action=action, delivery=delivery)
        return reply(200, "ignored")

    repo = payload["repository"]["full_name"]
    if repo != os.environ["ALLOWED_REPO"]:
        log(result="rejected", reason="repo_not_allowed", repo=repo, delivery=delivery)
        return reply(403, "repository not allowed")

    pr = payload["pull_request"]
    sha, number = pr["head"]["sha"], pr["number"]
    clone_url = pr["head"]["repo"]["clone_url"]
    token = secrets.get("github_token")

    set_commit_status(repo, sha, "pending", "Security scan started", token)

    try:
        resp = ecs.run_task(
            cluster=os.environ["CLUSTER"],
            taskDefinition=os.environ["TASK_DEFINITION"],
            launchType="FARGATE",
            count=1,
            networkConfiguration={"awsvpcConfiguration": {
                "subnets": os.environ["SUBNETS"].split(","),
                "securityGroups": [os.environ["SECURITY_GROUP"]],
                "assignPublicIp": "ENABLED",
            }},
            overrides={"containerOverrides": [{
                "name": os.environ["CONTAINER_NAME"],
                "environment": [
                    {"name": "REPO", "value": repo},
                    {"name": "CLONE_URL", "value": clone_url},
                    {"name": "COMMIT_SHA", "value": sha},
                    {"name": "PR_NUMBER", "value": str(number)},
                ],
            }]},
            tags=[{"key": "repo", "value": repo.replace("/", "_")},
                  {"key": "pr", "value": str(number)},
                  {"key": "commit", "value": sha}],
        )
        if resp.get("failures") or not resp.get("tasks"):
            raise RuntimeError(json.dumps(resp.get("failures")))
    except Exception as e:  # noqa: BLE001
        log(result="run_task_failed", repo=repo, pr=number, sha=sha, error=str(e))
        set_commit_status(repo, sha, "error", "Scan failed to start, push again to retry", token)
        return reply(500, "failed to start scan")

    task_arn = resp["tasks"][0]["taskArn"]
    log(result="scan_started", repo=repo, pr=number, sha=sha, action=action,
        task=task_arn, delivery=delivery)
    return reply(200, "scan started", task=task_arn)
