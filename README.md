# db-migrate

Move a whole database — schema **and** data — from one server to another, following
a five-phase workflow:

```
1. Requirements review & plan  →  2. Test migration  →  3. Tuning & plan review
                               →  4. Rehearsal       →  5. Production cutover
```

| Engine | Full load | CDC (keep in sync until cutover) |
|---|---|---|
| PostgreSQL | `pg_dump` → `pg_restore` | logical replication (publication + subscription) |
| MariaDB | `mariadb-dump` → `mariadb` | binlog replication from the dump's recorded position |
| MySQL | `mysqldump` → `mysql` | binlog replication from the dump's recorded position |
| MongoDB | `mongodump` → `mongorestore` | — not native; use mongosync or AWS DMS |

Same-engine (homogeneous) migrations only. Cross-engine pairs (e.g. MySQL → PostgreSQL)
are detected and refused, with a pointer to AWS DMS + DMS Schema Conversion — that
problem needs schema and code conversion, which native dump tools cannot do.

Runs anywhere that can reach both databases — laptop, bastion, CI runner, on-prem or
cloud. Client tools come from pinned Docker images; with no Docker, set
`CLIENT_MODE=local` and it uses the clients on your `PATH`.

## Quick start

```bash
./db-migrate init billing                    # creates billing.conf from the template
vi billing.conf                              # endpoints + requirements
export SRC_PASSWORD='…' TGT_PASSWORD='…'     # passwords only ever come from the environment

./db-migrate assess billing.conf             # 1. requirements review  → assessment.md
./db-migrate plan   billing.conf             #    strategy + schedule  → plan.md
./db-migrate run    billing.conf --phase test        # 2. test migration (timed, validated)
./db-migrate plan   billing.conf             # 3. re-plan with MEASURED throughput
./db-migrate run    billing.conf --phase rehearsal   # 4. rehearsal on a prod-sized copy
./db-migrate cutover billing.conf            # 5. production
```

Reports and state go to `runs/<name>/`: `assessment.md`, `plan.md`, `validation.md`,
and `runs.log` (each timed step — the source of the measured throughput).

## What each phase does

### 1. `assess` — requirements review

Checks every item on the requirements list against the real servers:

| Requirement | What is checked |
|---|---|
| Purpose | `PURPOSE=migration` (one-off move) or `replication` (long-term sync) |
| Targets | engines, versions (target older than source is flagged), connectivity to both, extensions available on the target, objects to move (views, functions, sequences, triggers, events, indexes), users/grants (always manual) |
| Encoding | source/target encoding and collation; non-Unicode columns are flagged for checking |
| Scale | data size, table and row counts, largest tables, LOB columns (`--deep` measures the longest value), tables without a primary key |
| Transaction log | WAL / binlog generation rate sampled for `SAMPLE_SECONDS` (MongoDB: oplog average and window) |
| CDC readiness | PostgreSQL: `wal_level=logical`, replication privilege, free slots, replica identity on every table. MariaDB/MySQL: `log_bin`, `binlog_format=ROW`, `REPLICATION SLAVE` + `RELOAD`, distinct `server_id` |

Problems come out as **blockers**, **warnings** and **notes**.

### 2. `plan` — strategy and schedule

- Estimates full-load time from size ÷ throughput (assumed `THROUGHPUT_MBPS` until a test
  run measures the real figure), plus `MARGIN_PCT` margin.
- **`full-load`** when load + validation + switch fits in `DOWNTIME_MINUTES`; otherwise
  **`full-load+cdc`**: load days in advance, keep in sync, cut over in minutes.
  `PURPOSE=replication` always means CDC. Override with `--strategy`.
- Works back from `DEADLINE` to dates for each phase, with a week of buffer for a retry,
  and warns when the deadline is too tight.
- Sizes the WAL/binlog the source must retain while the initial copy runs.

### 3–4. `run --phase test|rehearsal`

Full load (into an **empty** target — it refuses anything else), CDC start and catch-up
if the plan uses it, then validation. Every step is timed into `runs.log`, so re-running
`plan` uses the real throughput. `--keep-cdc` leaves replication running afterwards.

### 5. `cutover`

Asks you to type the migration name (or pass `--yes`), and expects application writes to
be stopped. Then:

- **full-load**: loads the production target and validates it.
- **full-load+cdc**: waits for replication to drain, copies PostgreSQL sequence values
  (logical replication does not carry them), validates (retrying while the last changes
  land), then stops CDC and removes the publication, subscription and slot.

If validation fails it stops **before** CDC is torn down and tells you not to switch.

## Steps on their own

```bash
./db-migrate full-load billing.conf [--phase …]
./db-migrate cdc start|status|wait|stop billing.conf
./db-migrate validate  billing.conf [--checksum]   # row counts + object counts; --checksum adds content hashes
./db-migrate report    billing.conf
```

## Things that are deliberately manual

- **Users, roles, grants** — never copied. Create them on the target before switching.
- **Schema changes during CDC** — DDL is not replicated. Freeze schema changes from
  `cdc start` until cutover.
- **Switching the application** — the tool tells you when it is safe; you change the
  connection strings.

## CDC networking

With CDC, the **target server** connects to the source (a PostgreSQL subscription or a
MariaDB/MySQL replica), not the machine running this tool. If the source has a different
address from the target's network, set `REPL_HOST` / `REPL_PORT`. For an RDS
MariaDB/MySQL target set `TGT_MANAGED=rds` (uses the `mysql.rds_*` procedures) and set
`replicate-do-db` in its parameter group.

## Security

- Passwords are read from `SRC_PASSWORD`, `TGT_PASSWORD` (`REPL_PASSWORD`) only, and reach
  the clients through the environment — never on a command line visible in `ps`.
  MongoDB tools get the URI from a private temp file.
- A PostgreSQL subscription stores its connection string (with the password) in the
  target's `pg_subscription` catalog until `cdc stop`/`cutover` drops it.
- `*.conf` and `runs/` are git-ignored; only `migration.example.conf` is tracked.

## Requirements

- bash 4+, coreutils, awk
- Docker (default) — or `CLIENT_MODE=local` with `psql`/`pg_dump`/`pg_restore`,
  `mariadb`/`mariadb-dump`, `mysql`/`mysqldump`, `mongosh`/`mongodump`/`mongorestore`.
- PostgreSQL: the client must be ≥ the server version (`PG_IMAGE`, default `postgres:17-alpine`).
