#!/usr/bin/env bash
# Usage: ./send_test.sh <webhook_url> <webhook_secret>
# Shows the three security checks for the video: no signature, wrong signature, non-PR event.
set -u
URL="$1"; SECRET="$2"

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$2" | sed 's/^.* //'; }
send() { # $1 label, $2 event, $3 body, $4 signature header (may be empty)
  echo "== $1"
  curl -s -w "  -> HTTP %{http_code}\n" -X POST "$URL" \
    -H "Content-Type: application/json" -H "X-GitHub-Event: $2" \
    ${4:+-H "X-Hub-Signature-256: $4"} -d "$3"
}

PR_BODY='{"action":"opened","pull_request":{"number":99},"repository":{"full_name":"attacker/repo"}}'
ISSUE_BODY='{"action":"opened","issue":{"number":1}}'

send "1) No signature (expect 401)"       pull_request "$PR_BODY"    ""
send "2) Wrong secret (expect 401)"       pull_request "$PR_BODY"    "sha256=$(sign "$PR_BODY" wrong-secret)"
send "3) Valid signature, issues event (expect 200 ignored)" issues "$ISSUE_BODY" "sha256=$(sign "$ISSUE_BODY" "$SECRET")"
send "4) Valid signature, other repo (expect 403)" pull_request "$PR_BODY" "sha256=$(sign "$PR_BODY" "$SECRET")"
