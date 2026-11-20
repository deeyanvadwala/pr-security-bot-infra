"""PR Security Bot - SAST scanner (runs as one Fargate task per PR event).

Contract (see SCANNER_CONTRACT.md):
  env in : REPO, CLONE_URL, COMMIT_SHA, PR_NUMBER, REPORT_BUCKET
  output : s3://REPORT_BUCKET/reports/<owner_repo>/<PR_NUMBER>/<COMMIT_SHA>/report.json
           stdout line RESULT=PASS or RESULT=FAIL  (FAIL = any HIGH severity finding)
  exit   : 0 when the scan completed (PASS or FAIL), 1 when the scan itself broke
Local testing: set SKIP_UPLOAD=1 to print the report instead of uploading it.
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

WORK_DIR = "/tmp/work"
REPO_DIR = f"{WORK_DIR}/repo"
BANDIT_OUT = f"{WORK_DIR}/bandit.json"


def log(**fields):
    print(json.dumps(fields), flush=True)


def run(cmd):
    subprocess.run(cmd, check=True, capture_output=True, text=True)


def main():
    start = time.time()
    repo = os.environ["REPO"]
    clone_url = os.environ["CLONE_URL"]
    sha = os.environ["COMMIT_SHA"]
    pr = os.environ["PR_NUMBER"]
    bucket = os.environ.get("REPORT_BUCKET", "")
    skip_upload = os.environ.get("SKIP_UPLOAD") == "1"
    log(stage="start", repo=repo, pr=pr, sha=sha)

    # 1. Clone the PR at the exact commit
    os.makedirs(WORK_DIR, exist_ok=True)
    run(["git", "clone", "--quiet", clone_url, REPO_DIR])
    run(["git", "-C", REPO_DIR, "checkout", "--quiet", sha])
    log(stage="cloned", sha=sha)

    # 2. Run Bandit (it exits 1 when it finds issues, so don't treat that as an error)
    subprocess.run(
        ["bandit", "-r", REPO_DIR, "-f", "json", "-o", BANDIT_OUT, "-q"],
        check=False, capture_output=True, text=True,
    )
    with open(BANDIT_OUT) as f:
        bandit = json.load(f)

    findings = [{
        "file": r["filename"].replace(REPO_DIR + "/", ""),
        "line": r["line_number"],
        "test_id": r["test_id"],
        "severity": r["issue_severity"],
        "confidence": r["issue_confidence"],
        "issue": r["issue_text"],
        "cwe": (r.get("issue_cwe") or {}).get("id"),
    } for r in bandit.get("results", [])]

    counts = {s: sum(1 for x in findings if x["severity"] == s) for s in ("HIGH", "MEDIUM", "LOW")}
    result = "FAIL" if counts["HIGH"] > 0 else "PASS"

    report = {
        "repo": repo, "pr_number": int(pr), "commit_sha": sha,
        "tool": "bandit", "result": result,
        "rule": "FAIL if any HIGH severity finding",
        "severity_counts": counts,
        "findings": findings,
        "scanned_at": datetime.now(timezone.utc).isoformat(),
        "duration_seconds": round(time.time() - start, 1),
    }

    # 3. Store the report in S3 (re-scanning the same commit overwrites it, no duplicates)
    key = f"reports/{repo.replace('/', '_')}/{pr}/{sha}/report.json"
    if skip_upload or not bucket:
        print(json.dumps(report, indent=2))
    else:
        import boto3
        boto3.client("s3").put_object(
            Bucket=bucket, Key=key, Body=json.dumps(report, indent=2).encode(),
            ContentType="application/json",
        )
        log(stage="uploaded", bucket=bucket, key=key)

    log(stage="done", result=result, high=counts["HIGH"], medium=counts["MEDIUM"],
        low=counts["LOW"], duration_seconds=report["duration_seconds"])
    print(f"RESULT={result}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        log(stage="error", error=str(e))
        print("RESULT=ERROR", flush=True)
        sys.exit(1)
