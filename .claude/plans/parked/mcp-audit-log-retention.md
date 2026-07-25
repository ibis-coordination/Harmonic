# MCP Audit Log Retention (spike)

**Status:** Not started. Spike — captures intent and shape so the eventual implementation has a starting point.

## Problem

`McpToolCallLog` is an append-only audit log of every MCP tool call: tool name, redacted args, status, duration, agent identity, tenant, request_id. At moderate steady-state traffic (60 calls/min/token × 100 active tokens) it grows ~8.6M rows/day. With no retention policy in place, the table grows unbounded and will eventually:

- Increase insert latency (index bloat, page splits)
- Push WAL volume and backup size up
- Make principal-review queries slow without per-partition indexes

We don't want to *delete* the data — it's valuable for accountability, debugging, abuse investigation, and product analytics. The goal is to keep it forever in a queryable form, but move old data off the hot path.

## Direction

Partition by month + archive cold partitions to S3 (or equivalent object storage). The live DB holds N months of recent data; older partitions are dumped to S3 and dropped from Postgres. A restore path exists for forensic / compliance work.

Roughly Option D from the security review discussion: indefinite retention via cold archive, not Option A (delete) or Option C (downsample + lose detail).

## Shape of the solution

### Schema migration (one-time)

Convert `mcp_tool_call_logs` to a Postgres declaratively-partitioned table keyed on `created_at`:

```sql
CREATE TABLE mcp_tool_call_logs (
  -- existing columns
) PARTITION BY RANGE (created_at);
```

- Pre-create N monthly partitions ahead of time (e.g. via a Sidekiq cron that ensures the next 3 months exist).
- Existing rows migrate into the appropriate partition during the cutover.
- All current indexes become per-partition; queries that include a `created_at` range get partition pruning for free.

### Hot retention window

- Keep **N months of live partitions** (start with 12; tune based on principal-review UI requirements and DB size).
- Insert goes to the current month's partition; old partitions are read-only for application code.

### Cold archive

When a partition ages out of the hot window, a Sidekiq job (or rake task):

1. `pg_dump` the partition (or use `COPY ... TO STDOUT`) into a Parquet or compressed CSV file.
2. Upload to S3 under a structured prefix: `s3://harmonic-mcp-audit/{tenant_id}/{year}/{month}.parquet`.
3. Record a row in a new `mcp_tool_call_log_archives` table: partition name, S3 path, row count, archive timestamp, checksum.
4. `DROP TABLE` the partition.

The archive row is the index — restore is "find the archive, download, load into a temp table."

### Restore path

For forensic / compliance work, an operator-only command (Rails task or admin API):

```ruby
McpToolCallLogArchive.restore!(tenant_id:, month:)
```

Reads the S3 object, creates a temporary partition, attaches it. The data is queryable like any other partition until manually re-archived. Not optimized for frequent use — meant for "we need to investigate something from 2027."

### Format choice (open question)

Parquet is the natural choice for analytical access (column-oriented, compressed, integrates with Athena/DuckDB without a DB roundtrip). CSV/JSON is simpler but bigger and slower to query in cold.

Decide based on whether cold queries are an actual use case. If "restore to DB" is the only path, CSV is fine. If "query directly from S3 via Athena/DuckDB" is desirable for analytics, Parquet wins.

## Cross-cutting concerns

### GDPR / user deletion

When a user is hard-deleted (right to be forgotten), their rows must be removed or anonymized — both live and archived. Approaches:

- **Anonymize at archive time** — strip `user_id`, replace with a hash. Then user deletion doesn't need to touch archives.
- **Per-user delete propagation** — keep user_id, but when a user is deleted, find archived partitions containing their rows, restore, delete those rows, re-archive. Complex but accurate.

Lean toward anonymization at archive time. Live partitions retain identity for the hot window; cold archives don't, which is the right tradeoff for both GDPR and storage size.

This also means the GDPR-deletion code path needs to delete live `McpToolCallLog` rows for the deleted user. Worth adding to the existing user-deletion service *before* this spike is implemented (cheap, future-proof).

### Tenant-configurable retention

The hot window length is a Harmonic-operator decision (storage cost), not a tenant preference. Don't expose to tenant admins. (Same posture as `Tenant#mcp_aggregate_rate_limit_per_minute`.)

A self-hosted deployment of Harmonic might want a different hot window (smaller default if running on a smaller DB). Configurable via an ENV var or a settings table — not via tenant settings.

### Backups

Postgres backups will include the partitions that exist at backup time. Once a partition is archived + dropped, it's no longer in new backups. Backups + archives together cover the full history.

For real GDPR compliance, deletion must propagate to **backups** too — auto-expire backups after the maximum legal retention window (varies by jurisdiction; 30 days is a common default for routine deletion).

### Observability

The retention/archive job is operator-facing. Surface:

- Archive job success/failure to SecurityAuditLog or a metrics dashboard
- Last-archived-partition timestamp (alert if it's > N months stale)
- Per-tenant archive size in S3 (cost monitoring)

## Decisions to make at build time

- **Hot window length** — 12 months is a starting point. Storage cost vs. principal-review UI requirements drive this.
- **Archive format** — Parquet if we want cold analytical queries; CSV if "restore to live DB" is the only access pattern.
- **GDPR anonymization vs. delete-propagation** — recommended: anonymize at archive.
- **Restore tooling** — Rails task is fine; no need for a UI unless restores become routine.
- **Multi-tenant archiving** — partition by `created_at` only, or also by `tenant_id`? Single-axis partitioning is simpler; two-axis allows per-tenant retention policies later.

## What this is NOT

- Not a real-time analytics platform. For "show me my agent's recent activity" the live `McpToolCallLog` table is the source.
- Not a replacement for backups. Archives are additive.
- Not free. S3 storage + transfer + occasional restore time is a real ongoing cost. Probably small relative to DB storage, but should be modeled.

## When to do this

When **any** of:
- Total `McpToolCallLog` row count passes ~50M, or
- Insert latency on the table starts climbing measurably, or
- The principal-review UI needs to answer queries that span > current hot window, or
- A compliance / customer-data audit asks "where does this data live and how long do you keep it?"

Until then, the data lives in the live table with the model docstring's note about the gap.
