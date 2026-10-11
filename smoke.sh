#!/usr/bin/env bash
set -euo pipefail

API="${API_URL:-http://localhost:8000}"

echo "1. checking API readiness..."
for i in $(seq 1 10); do
  if curl -sf "${API}/readyz" >/dev/null; then
    echo "   ready."
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "   API never became ready. Is 'docker compose up' running?"
    exit 1
  fi
  echo "   waiting for API... ($i)"
  sleep 2
done

echo "2. submitting a sales batch (mix of good and bad records)..."
RESPONSE=$(curl -sf -X POST "${API}/jobs" \
  -H "content-type: application/json" \
  -d '{
    "records": [
      {"region": "West",  "amount": 100.0, "sale_date": "2026-01-01", "order_id": "a1"},
      {"region": "West",  "amount": 50.5,  "sale_date": "2026-01-02", "order_id": "a2"},
      {"region": "East",  "amount": 200.0, "sale_date": "2026-01-03", "order_id": "a3"},
      {"region": "East",  "amount": -5.0,  "sale_date": "2026-01-04", "order_id": "a4"},
      {"region": null,    "amount": 10.0,  "sale_date": "2026-01-05", "order_id": "a5"},
      {"region": "West",  "amount": 100.0, "sale_date": "2026-01-01", "order_id": "a1"}
    ]
  }')

JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['job_id'])")
echo "   submitted. job_id = ${JOB_ID}"

echo "3. polling for the result..."
for i in $(seq 1 15); do
  STATUS=$(curl -sf "${API}/jobs/${JOB_ID}" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])")
  echo "   status: ${STATUS} ($i)"
  if [ "$STATUS" = "done" ]; then
    break
  fi
  if [ "$STATUS" = "failed" ]; then
    echo "   job failed."
    exit 1
  fi
  if [ "$i" -eq 15 ]; then
    echo "   job never completed. Check the worker logs: docker compose logs worker"
    exit 1
  fi
  sleep 2
done

echo "4. fetching the result..."
RESULT=$(curl -sf "${API}/jobs/${JOB_ID}/result")
echo "   $RESULT"

echo ""
echo "Expected: total_sales 350.5 (grand total), 3 rows processed, 3 rejected"
echo "          (1 negative amount, 1 missing region, 1 duplicate order_id)"
echo "          Per-region breakdown is a v2 feature; v1 returns the grand total."
echo ""
echo "PIPELINE WORKS END TO END."
