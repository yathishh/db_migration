# db-migrate

Move a whole database — schema **and** data — from one server to another, following
a five-phase workflow:

```
1. Requirements review & plan  →  2. Test migration  →  3. Tuning & plan review
                               →  4. Rehearsal       →  5. Production cutover
```

**Any engine to any engine** — PostgreSQL, MariaDB, MySQL, MongoDB — with no AWS DMS.

### Same engine

| Engine | Full load | CDC (keep in sync until cutover) |
|---|---|---|
| PostgreSQL | `pg_dump` → `pg_restore` | logical replication (publication + subscription) |
| MariaDB | `mariadb-dump` → `mariadb` | binlog replication from the dump's recorded position |
| MySQL | `mysqldump` → `mysql` | binlog replication from the dump's recorded position |
| MongoDB | `mongodump` → `mongorestore` | — not native; use mongosync |

MariaDB ⇄ MySQL goes through the converter below, not a raw dump: each rejects the
other's default collation (`utf8mb4_uca1400_ai_ci` / `utf8mb4_0900_ai_ci`) and some
types. Column types are kept exactly (unsigned, ENUM/SET, TIMESTAMP, ON UPDATE);
only the collation and the types one side lacks change. Full load only.

### Different engines (`lib/xengine.sh`)

The tool converts the schema itself and transforms every row in flight. Nothing is
written to disk.

| From → to | Schema | Data path |
|---|---|---|
| PostgreSQL → MariaDB/MySQL | tables, types, keys, defaults, auto-increment, indexes, FKs converted | `SELECT` formats MySQL literals → batched multi-row `INSERT` |
| MariaDB/MySQL → PostgreSQL | same, plus ENUM → `CHECK`, `TINYINT(1)` → boolean, unsigned → wider types | `SELECT` formats COPY text → `COPY … FROM STDIN` |
| SQL → MongoDB | one collection per table; indexes → `createIndex` (unique ones keep SQL's "many NULLs allowed") | one Extended-JSON document per row → `mongoimport` |
| MongoDB → SQL | one table per collection: `_id` + the whole document in `jsonb` / `JSON` | `mongoexport` → `COPY` / `INSERT` |

Types are kept, not stringified. To MongoDB: dates → `ISODate` (UTC), BIGINT → long,
DECIMAL and BIGINT UNSIGNED → Decimal128, binary → BinData, JSON → embedded documents,
booleans → booleans, doubles stay doubles. From MongoDB: nothing is lost, because each
document is stored whole as relaxed Extended JSON.

What cross-engine **cannot** do, by design:

- **Views, functions, procedures, triggers, events, check constraints, MongoDB
  validators** — these are code in one engine's dialect. Translating them mechanically
  produces SQL that runs and gives wrong answers. They are exported to
  `xengine/manual_objects.*` and listed in `conversion.md` for a human to rewrite.
- **CDC** — there is no native way to replicate from one engine into another. A
  cross-engine migration is a full load inside the downtime window; `plan` tells you
  whether it fits (raise `JOBS`, exclude data, or use a CDC pipeline such as Debezium
  if it does not).
- **Expression / partial / full-text / GIN indexes** — listed as warnings to re-create.

`assess` produces `conversion.md` before anything is touched: the type mapping, every
lossy or behavioural difference (case sensitivity, zero dates, `timestamptz` → UTC
`DATETIME`), and the objects needing manual work. The generated DDL is in
`xengine/schema.sql`, `indexes.sql` and `fks.sql`, ready for review.

Cross-engine validation compares, per table, the row count, the sum of every
integer/boolean column and the total characters of every text column, each computed
independently by both engines (`--checksum`). Indexes and FKs that failed to create
count as failures.

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

## Tested

```bash
tests/e2e.sh                  # all 16 directions (needs Docker, ~5 minutes)
tests/e2e.sh mysql postgres   # one direction
```

Starts PostgreSQL 16, MariaDB 11, MySQL 8.4 and MongoDB 7, seeds each with the same
hostile dataset (quotes, backslashes, newlines and tabs, emoji, empty string vs NULL,
trailing spaces, binary containing NUL/quote/backslash, decimals, single-precision
floats, booleans, timestamps, JSON, a composite key, a foreign key, a view, a function),
and migrates **every source to every target**.

Each direction must pass two independent checks:

1. **Tool** — db-migrate's own `assess → plan → run → validate --checksum`.
2. **Data** — a fingerprint computed by the source and the target engine themselves,
   outside the tool: row count, MD5 of every text value, MD5 of every binary value,
   MD5 of every timestamp, the decimal sum, the boolean count, the float sum.

The latest run is in [tests/RESULTS.md](tests/RESULTS.md).

CDC has its own suite, with a separate TLS-only source and target per engine:

```bash
tests/cdc.sh                  # PostgreSQL, MariaDB, MySQL (~4 minutes)
```

It loads the target, starts replication with `REPL_SSL=verify`, makes inserts, updates
and deletes on the source while replication runs, cuts over, and then checks that the
data is identical, that the live changes arrived, that the replication link itself was
encrypted, and that nothing (slot, publication, subscription, replica configuration) is
left behind. The latest run is in [tests/RESULTS-CDC.md](tests/RESULTS-CDC.md).

Not yet exercised: managed services (RDS/Aurora with `TGT_MANAGED=rds`, Atlas,
DocumentDB), databases using extensions, macOS.

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

### Encryption in transit — on by default

Data moves source → tool → target, and with CDC target → source. Every one of those
connections is TLS-encrypted by default, and nothing falls back to plain text.

| Mode | What it guarantees |
|---|---|
| `require` (default) | Encrypted. The tool refuses to run if the server cannot do TLS. |
| `verify` | Encrypted **and** the server's certificate and hostname are checked against your CA (`SRC_SSL_CA` / `TGT_SSL_CA`). Also stops a man-in-the-middle. Use this for production. |
| `disable` | Plain text. Refused unless `ALLOW_INSECURE_TRANSPORT=yes` is set explicitly. |

- `prefer` is **not accepted**: it quietly downgrades to plain text when a server does
  not offer TLS.
- `assess` asks each **server** what protects the session and records the TLS version
  and cipher in `assessment.md`. An unencrypted connection is a blocker.
- The CDC connection (PostgreSQL subscription, MariaDB/MySQL replica) uses TLS too
  (`REPL_SSL`, default `require`; `verify` with `REPL_SSL_CA_PATH` on the target server).
- Rows are never written to disk on the way: they stream through memory from one TLS
  connection into the other. (One exception: PostgreSQL with `JOBS>1` stages the dump in
  a temporary directory that is deleted afterwards.)
- A remote Docker daemon over plain `tcp://` is refused — the stream would cross the
  network unencrypted.
- The CA bundle is passed to the client as text and written to a private temp file
  inside it; no host directory is mounted.

`tests/e2e.sh` proves this on every run: all four servers accept **only** TLS, every
migration runs in `verify` mode, and plain-text logins, an untrusted CA and insecure
tool settings are each shown to be refused.

Encryption **at rest** (the disks of the source and target servers, their backups) is
the database platform's job — RDS/Aurora storage encryption, LUKS, MongoDB encrypted
storage engine — not something a migration tool can add.

### Credentials

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
