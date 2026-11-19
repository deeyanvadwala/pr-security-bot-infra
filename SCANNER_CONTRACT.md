# Contract between event side and scanner side

The Lambda starts the Fargate task with container name `scanner` and these env vars:

| Variable       | Example                                   | Set by         |
|----------------|-------------------------------------------|----------------|
| REPO           | owner/test-repo                           | Lambda         |
| CLONE_URL      | https://github.com/owner/test-repo.git    | Lambda         |
| COMMIT_SHA     | full 40-char head commit SHA              | Lambda         |
| PR_NUMBER      | 3                                         | Lambda         |
| REPORT_BUCKET  | pr-bot-reports-<account-id>               | Task definition|

The scanner container must:
1. `git clone $CLONE_URL`, then `git checkout $COMMIT_SHA`
2. Run the SAST scan
3. Upload to `s3://$REPORT_BUCKET/reports/<owner_repo>/<PR_NUMBER>/<COMMIT_SHA>/report.json`
   (replace "/" in REPO with "_")
4. Print `RESULT=PASS` or `RESULT=FAIL` to stdout (shows in CloudWatch) and exit 0
   (FAIL = at least one high-severity finding)

The image's own ENTRYPOINT/CMD runs the scan (the task definition sets no command
when use_placeholder_scanner = false). Credentials for S3 come from the task role (LabRole),
so no AWS keys go into the image.
