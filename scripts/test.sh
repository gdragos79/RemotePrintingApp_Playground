#!/usr/bin/env bash
set -euo pipefail
NS=remote-print
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for this test. Install with: sudo apt-get install -y jq" >&2
  exit 1
fi
kubectl -n "$NS" wait --for=condition=available --timeout=180s deployment/postgres || true
kubectl -n "$NS" wait --for=condition=available --timeout=180s deployment/backend || true
kubectl -n "$NS" wait --for=condition=available --timeout=180s deployment/frontend || true

if command -v minikube >/dev/null 2>&1 ; then
  URL=$(minikube service -n "$NS" frontend --url | head -n1)
else
  URL="http://localhost:30080"
fi
echo "Frontend: $URL"

USER="alice"; PASS="password123"
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL/api/register" -H "Content-Type: application/json" -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" || true
TOKEN=$(curl -s -X POST "$URL/api/login" -H "Content-Type: application/json" -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" | jq -r .token)
if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then echo "Login failed"; exit 1; fi

TMPFILE=$(mktemp /tmp/print-XXXX.txt)
echo "Hello from test $(date)" > "$TMPFILE"
JOB_ID=$(curl -s -X POST "$URL/api/print" -H "Authorization: Bearer $TOKEN" -F "file=@$TMPFILE" | jq -r .job_id)
echo "Job: $JOB_ID"

for i in $(seq 1 10); do
  STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/jobs/$JOB_ID" | jq -r .status)
  echo "  attempt $i: $STATUS"
  if [[ "$STATUS" == "completed" || "$STATUS" == "failed" ]]; then break; fi
  sleep 1
done
echo "Done."
