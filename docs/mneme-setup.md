# Mneme Setup

DSM-side runbook for provisioning the read-only Postgres user that nas-observability's `postgres_exporter` uses to scrape Mneme's database. Do this **once per NAS** before deploying F003's compose update; subsequent F003 deploys don't need it.

This runbook is the F003-equivalent of `docs/snmp-setup.md` (F002's SNMP enablement). Same shape: a one-time NAS-side action that lives in a runbook because Constitution Principle II carves out manual NAS configuration as the documented exception to declarative-from-the-repo.

## Prerequisites

- **F002 stack deployed and running** on the DS224+ (five containers healthy per `sudo bash scripts/diagnose.sh`).
- **Mneme stack deployed and running** on the same DS224+. Mneme's Postgres exposes itself on `localhost:5433` (host networking; port 5433 chosen because DSM owns 5432).
- SSH access to the NAS with `sudo`.

## Step 1 — Generate the metrics-user password

On the NAS shell (or your workstation; copy the output to the NAS):

```bash
openssl rand -base64 24
```

Outputs a 32-char URL-safe random string. **Save it now** — Step 3 needs it again, and after that it lives in Portainer's stack environment field. There's no other copy.

For the rest of this runbook, the saved value is referenced as `${METRICS_PW}`. Set it in your shell so the commands below work as written:

```bash
export METRICS_PW='<paste-the-generated-password-here>'
```

## Step 2 — Run the provisioning SQL via `docker exec`

Pipe a single idempotent DO block into psql inside Mneme's Postgres container. The DO block creates `mneme_metrics` on first run, ALTERs the password on subsequent runs (so a rotated password doesn't require a separate flow), and unconditionally GRANTs `pg_monitor` (granting an already-held role is a Postgres no-op).

```bash
docker exec -i mneme-postgres-1 sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -p "${MNEME_PG_PORT:-5433}"' <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mneme_metrics') THEN
    CREATE USER mneme_metrics WITH PASSWORD '${METRICS_PW}';
  ELSE
    ALTER USER mneme_metrics WITH PASSWORD '${METRICS_PW}';
  END IF;
END \$\$;

GRANT pg_monitor TO mneme_metrics;
SQL
```

**Why the `sh -c 'exec psql ...'` wrapper:** Mneme's compose sets `POSTGRES_USER`, `POSTGRES_DB`, and `MNEME_PG_PORT` as container env vars (not exported to the host). Running `psql` via `sh -c 'exec psql ...'` inside the container uses those env vars directly without copying them to the host. `exec` replaces the shell with psql so stdin (the heredoc) flows straight to psql.

**Why the `\$\$` escaping:** the heredoc passes through bash, which treats `$$` as the shell PID. Escaping to `\$\$` keeps the dollar signs literal so psql sees a proper DO block delimiter.

**Expected output:**

```
DO
GRANT
```

Two lines. If you see `ERROR: role "mneme_metrics" already exists`, the DO block didn't take effect (older Postgres without DO support, or syntax error in the heredoc) — check Step 4's troubleshooting.

## Step 3 — Set `POSTGRES_METRICS_PASSWORD` in Portainer

In Portainer's web UI:

1. **Stacks → nas-observability → Editor** (or whatever you named the F002 stack).
2. Scroll to **Environment variables**.
3. Add or update: `POSTGRES_METRICS_PASSWORD=<the-generated-password>`.
4. Save the stack environment. **Do NOT redeploy yet** — wait for Step 5 to redeploy with the F003 compose changes merged.

The password is now in Portainer's encrypted env store. It is **not** in `.env.example` and **not** in the repo; the only places it exists are Portainer + your password manager.

## Step 4 — Verify connectivity from the NAS shell

Before redeploying, sanity-check that the metrics user can actually connect to Postgres and read `pg_stat_*`:

```bash
docker exec -i mneme-postgres-1 sh -c 'exec psql -U mneme_metrics -d postgres -p "${MNEME_PG_PORT:-5433}"' <<<"SELECT count(*) FROM pg_stat_database;"
```

You'll be prompted for the password (Postgres prompts because no `~/.pgpass` is set in the container). Paste `${METRICS_PW}`.

**Expected output:** a single integer, typically 4–8 depending on how many databases Mneme's Postgres has (system DBs `template0`, `template1`, `postgres`, plus Mneme's app DB).

If the query fails:

- **Authentication failed:** wrong password (re-check Step 1's saved value vs. what Step 2 actually used).
- **Role does not exist:** Step 2's DO block didn't run successfully. Re-run Step 2.
- **No `pg_monitor` privilege:** the `GRANT` didn't apply. Check `docker exec mneme-postgres-1 psql -U postgres -c '\du'` and look for `mneme_metrics` with `Member of: {pg_monitor}`.

## Step 5 — Redeploy nas-observability stack with F003 compose

Once F003's `docker-compose.yml` (postgres-exporter service added, memory rebalance applied) is merged to `main` and CI has rebuilt the Grafana image:

In Portainer: **Stacks → nas-observability → Update** with **Pull and redeploy** + **Re-pull image** enabled. The compose change picks up `POSTGRES_METRICS_PASSWORD` from the env you set in Step 3 and substitutes it into postgres-exporter's `DATA_SOURCE_NAME`.

Verify with `sudo bash /tmp/diagnose.sh` (re-fetch via `curl -fsSL -o /tmp/diagnose.sh https://raw.githubusercontent.com/mstellaris/nas-observability/main/scripts/diagnose.sh` if needed):

- Six containers running (the F002 five + new `postgres-exporter`).
- Section 5 shows port 9187 listening.
- `http://<nas-ip>:9090/targets` shows `mneme-postgres` job UP within ~30s of redeploy (one scrape cycle).

## Troubleshooting

### `ERROR: role "mneme_metrics" already exists`

If Step 2 reports this **as an error** (not silently absorbed by the DO block), the DO block syntax didn't reach Postgres correctly. Most likely cause: the heredoc's `\$\$` got misinterpreted by your shell. Verify by running the same command but capturing stdin first:

```bash
cat <<SQL > /tmp/provision.sql
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mneme_metrics') THEN
    CREATE USER mneme_metrics WITH PASSWORD '${METRICS_PW}';
  ELSE
    ALTER USER mneme_metrics WITH PASSWORD '${METRICS_PW}';
  END IF;
END \$\$;
GRANT pg_monitor TO mneme_metrics;
SQL

cat /tmp/provision.sql  # Verify it shows DO $$, not DO 12345$$
docker exec -i mneme-postgres-1 sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -p "${MNEME_PG_PORT:-5433}"' < /tmp/provision.sql
rm /tmp/provision.sql
```

If `cat /tmp/provision.sql` shows `DO $$` (correct) but Postgres still rejects it, you're on a Postgres version below 9.0 (no DO block support). Mneme uses pgvector/pgvector:pg16 per its compose, so this shouldn't occur.

### `mneme-postgres` scrape job reports DOWN after Step 5

`docker logs postgres-exporter` shows the actual error. Most common causes:

- **`pq: password authentication failed for user "mneme_metrics"`** — the password in Portainer doesn't match the one in Step 2's SQL. Re-do Step 3, then redeploy.
- **`pq: role "mneme_metrics" does not exist`** — Step 2's DO block didn't execute. Re-run Step 2.
- **`dial tcp 127.0.0.1:5433: connect: connection refused`** — Mneme's Postgres isn't running on the expected port. Verify with `docker ps --filter name=mneme-postgres`. If Mneme's compose changed `MNEME_PG_PORT`, F003's compose `DATA_SOURCE_NAME` URI needs to match (currently hardcoded to 5433; see Plan §Service Configuration: postgres_exporter for forks).

### `pg_stat_statements` extension not installed

Some database dashboard panels (slow queries) depend on the `pg_stat_statements` extension. If Mneme's Postgres doesn't have it enabled, those panels render with the `noValue` text per F003's plan — they don't error, they just show "extension not installed."

To enable (one-time, optional — improves database dashboard's slow-query visibility):

```bash
docker exec -i mneme-postgres-1 sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -p "${MNEME_PG_PORT:-5433}"' <<SQL
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
```

This requires `shared_preload_libraries = 'pg_stat_statements'` in `postgresql.conf`. If the extension isn't already loaded by Mneme's compose, enabling at runtime requires a Postgres restart (`docker restart mneme-postgres-1`). Coordinate with Mneme's owner if they care about restart timing.

### Cleaning up `${METRICS_PW}` from your shell

After Step 3, the password is no longer needed in your shell environment:

```bash
unset METRICS_PW
history -c    # if your shell records history and you typed the password inline
```

Same hygiene as F002's `.community` setup.
