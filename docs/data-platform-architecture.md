# Data Platform Architecture

This clone extends the original Kubernetes learning project into a local data platform for API discovery, validation, enrichment, SQL storage, queue-based ingestion, and Trino-based query serving.

For deployment and operations details, see:

- `docs/complete-deployment-and-operations-guide.md`
- `docs/troubleshooting-guide.md`

## Core Flow

1. `api-discovery` crawls public API sources.
2. It writes jobs to RabbitMQ.
3. `api-validator` and `api-enricher` consume queued work.
4. Results are stored in Postgres.
5. `query-router` sends analytical queries to Trino.
6. `frontend` provides a simple user interface.
7. Prometheus, Grafana, Loki, and Alertmanager observe the stack.
8. KEDA scales the workers using queue depth.

## Namespaces

- `data-platform` - API discovery, validation, enrichment, query routing.
- `messaging` - RabbitMQ.
- `store` - Postgres.
- `analytics` - Trino.
- `frontend` - web UI.
- `monitoring` - existing observability stack from the cloned project.

## Notes

- Service images are built locally as `data-platform/*:local` and loaded into kind.
- Trino and Postgres are intentionally separated to model compute vs storage.
- For local Kind usage, start with 1 coordinator and 2 workers; add more workers if you want to test Trino load balancing.
