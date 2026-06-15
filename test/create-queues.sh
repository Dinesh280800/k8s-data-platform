#!/usr/bin/env bash
# Creates the three KEDA-watched queues in RabbitMQ.
# Run this once after RabbitMQ starts or after a pod restart wipes state.
set -euo pipefail
HOST="${RABBITMQ_HOST:-localhost}"
PORT="${RABBITMQ_PORT:-15672}"
USER="${RABBITMQ_USER:-guest}"
PASS="${RABBITMQ_PASS:-guest}"
QUEUES=(api-discovery-jobs api-validator-jobs api-enrichment-jobs)
for q in "${QUEUES[@]}"; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -u "${USER}:${PASS}" \
    -X PUT "http://${HOST}:${PORT}/api/queues/%2F/${q}" \
    -H 'Content-Type: application/json' \
    -d '{"durable":true}')
  echo "  ${q}: HTTP ${code}"
done
