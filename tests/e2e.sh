#!/usr/bin/env bash
# End-to-end test: every source engine → every target engine (16 directions).
#
#   tests/e2e.sh                 run the whole matrix
#   tests/e2e.sh mysql postgres  run one direction
#   KEEP=1 tests/e2e.sh          leave the containers running afterwards
#
# One server per engine (PostgreSQL 16, MariaDB 11, MySQL 8.4, MongoDB 7) is
# started in Docker and seeded with the same hostile dataset: quotes,
# backslashes, newlines and tabs, emoji, empty strings vs NULLs, trailing
# spaces, HTML entities, binary containing NUL/quote/backslash/newline,
# decimals, single-precision floats, booleans, timestamps, JSON, a composite
# key, a foreign key, a view and a function.
#
# Each direction is migrated with db-migrate (assess → plan → run --checksum),
# then checked INDEPENDENTLY of the tool: the source and the target engine each
# compute a fingerprint of the `people` table through their own client —
#   rows | md5(all names) | sum(amount) | count(active) | md5(all binaries)
#        | md5(all timestamps to the second) | sum(float column, 6 dp)
# — and the two must be identical. Results go to tests/RESULTS.md.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$HERE/.work"
PW=e2e-pw
N="${N:-1000}"
ENGINES=(postgres mariadb mysql mongodb)

C_PG=dbm-e2e-pg; C_MARIA=dbm-e2e-maria; C_MYSQL=dbm-e2e-mysql; C_MONGO=dbm-e2e-mongo
B="${E2E_PORT_BASE:-57100}"
declare -A PORT=([postgres]=$((B + 1)) [mariadb]=$((B + 2)) [mysql]=$((B + 3)) [mongodb]=$((B + 4)))
declare -A USER_OF=([postgres]=postgres [mariadb]=root [mysql]=root [mongodb]=root)

log() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

# ── servers ─────────────────────────────────────────────────────────────────

# A throwaway CA and a server certificate valid for 127.0.0.1 / localhost, so
# every test connection can run in the strictest mode (verify: encrypted, and
# the server's certificate and hostname checked against this CA).
certs() {
  local d="$WORK/certs"
  rm -rf "$d"; mkdir -p "$d"
  (
    cd "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=db-migrate e2e CA" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > ext.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile ext.cnf 2>/dev/null
    cat server.crt server.key > server.pem
    # a second, unrelated CA: verifying against it must FAIL (impostor test)
    openssl req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other-ca.pem -days 2 -subj "/CN=some other CA" 2>/dev/null
    chmod 644 ./*
  )
}

# run_tls <name> <image> <owner> <server command…> — the certificates are
# copied in before start and handed to the server's own user.
run_tls() {
  local name="$1" image="$2" owner="$3"; shift 3
  docker create --name "$name" "${ENVS[@]}" --entrypoint sh "$image" \
    -c "mkdir -p /certs && cp /certs-in/* /certs/ && chown -R $owner /certs && chmod 600 /certs/server.key && exec docker-entrypoint.sh $*" >/dev/null
  docker cp "$WORK/certs/." "$name:/certs-in"
  docker start "$name" >/dev/null
}

start() {
  log "starting TLS-only servers"
  docker rm -f "$C_PG" "$C_MARIA" "$C_MYSQL" "$C_MONGO" >/dev/null 2>&1 || true
  local p
  for p in "${PORT[@]}"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "port $p is already in use by something else — set E2E_PORT_BASE to a free range" >&2; exit 2
    fi
  done
  certs
  ENVS=(-e POSTGRES_PASSWORD=$PW -p ${PORT[postgres]}:5432)
  run_tls "$C_PG" postgres:16-alpine postgres \
    "postgres -c ssl=on -c ssl_cert_file=/certs/server.crt -c ssl_key_file=/certs/server.key -c ssl_min_protocol_version=TLSv1.2"
  ENVS=(-e MARIADB_ROOT_PASSWORD=$PW -p ${PORT[mariadb]}:3306)
  run_tls "$C_MARIA" mariadb:11 mysql \
    "mariadbd --ssl-cert=/certs/server.crt --ssl-key=/certs/server.key --ssl-ca=/certs/ca.pem --require-secure-transport=ON --tls-version=TLSv1.2,TLSv1.3"
  ENVS=(-e MYSQL_ROOT_PASSWORD=$PW -p ${PORT[mysql]}:3306)
  run_tls "$C_MYSQL" mysql:8.4 mysql \
    "mysqld --ssl-cert=/certs/server.crt --ssl-key=/certs/server.key --ssl-ca=/certs/ca.pem --require-secure-transport=ON --tls-version=TLSv1.2,TLSv1.3"
  ENVS=(-e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=$PW -p ${PORT[mongodb]}:27017)
  run_tls "$C_MONGO" mongo:7 mongodb \
    "mongod --tlsMode requireTLS --tlsCertificateKeyFile /certs/server.pem --tlsCAFile /certs/ca.pem --tlsAllowConnectionsWithoutCertificates"

  # pg_isready also answers during the image's init phase; wait for the real start.
  wait_for "$C_PG" sh -c "docker logs $C_PG 2>&1 | grep -q 'PostgreSQL init process complete'"
  wait_for "$C_PG" docker exec "$C_PG" pg_isready -U postgres -q
  # Network connections: TLS only. (The local socket stays open for the
  # harness's own checks, which run inside the container.)
  docker exec "$C_PG" sh -c 'printf "local all all trust\nhostssl all all all scram-sha-256\nhostnossl all all all reject\n" > "$PGDATA/pg_hba.conf"'
  docker exec "$C_PG" psql -U postgres -qc 'SELECT pg_reload_conf()' >/dev/null
  wait_for "$C_MARIA" docker exec "$C_MARIA" healthcheck.sh --connect
  wait_for "$C_MYSQL" docker exec -e MYSQL_PWD=$PW "$C_MYSQL" mysql -uroot -e 'SELECT 1'
  wait_for "$C_MONGO" mgjs admin 'print(1)'
  sleep 2
}

# wait_for <container> <command…> — until the command succeeds; gives up (with
# the server's log) after two minutes or as soon as the container has died.
wait_for() {
  local c="$1" i; shift
  for i in $(seq 1 60); do
    "$@" >/dev/null 2>&1 && return 0
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then break; fi
    sleep 2
  done
  echo "server $c did not become ready:" >&2
  docker logs "$c" 2>&1 | tail -8 >&2
  exit 3
}

pgq()  { docker exec "$C_PG" psql -U postgres -d "$1" -X -At -F'|' -v ON_ERROR_STOP=1 -c "$2"; }
myq()  { # myq <engine> <db> <sql>   (local socket inside the container)
  local c bin; if [ "$1" = mariadb ]; then c=$C_MARIA; bin=mariadb; else c=$C_MYSQL; bin=mysql; fi
  docker exec -i -e MYSQL_PWD=$PW "$c" $bin -uroot --default-character-set=utf8mb4 -N -B ${2:+"$2"} -e "$3" | tr '\t' '|'
}
mgjs() {
  docker exec "$C_MONGO" mongosh --quiet --tls --tlsCAFile /certs/ca.pem --host localhost \
    -u root -p $PW --authenticationDatabase admin --eval "const d = db.getSiblingDB('$1'); $2"
}

# ── security checks ─────────────────────────────────────────────────────────
# Each must hold, or the run fails:
#   1. every server refuses a plain-text connection (so no one can read the
#      traffic even with a misconfigured client)
#   2. db-migrate itself refuses plain text and "prefer" unless explicitly allowed
#   3. every migration's assessment shows the TLS version + cipher the SERVER
#      reported for both connections
declare -a SEC=()
sec() { # sec <description> <expect: refused|accepted> <command…>
  local what="$1" expect="$2"; shift 2
  local got=accepted
  "$@" >/dev/null 2>&1 || got=refused
  if [ "$got" = "$expect" ]; then SEC+=("| $what | $got | ✅ |"); else SEC+=("| $what | $got (expected $expect) | ❌ |"); fi
  printf '  %-62s %s\n' "$what" "$( [ "$got" = "$expect" ] && echo "✅ $got" || echo "❌ $got" )"
}

security_checks() {
  log "security: plain text must be refused"
  sec "PostgreSQL: plain-text login (sslmode=disable)" refused \
    docker run --rm --network host -e PGPASSWORD=$PW postgres:17-alpine \
      psql "host=127.0.0.1 port=${PORT[postgres]} user=postgres dbname=postgres sslmode=disable" -c 'SELECT 1'
  sec "PostgreSQL: TLS login, certificate verified (verify-full)" accepted \
    docker run --rm --network host -e PGPASSWORD=$PW -v "$WORK/certs/ca.pem:/ca.pem:ro" postgres:17-alpine \
      psql "host=127.0.0.1 port=${PORT[postgres]} user=postgres dbname=postgres sslmode=verify-full sslrootcert=/ca.pem" -c 'SELECT 1'
  sec "MariaDB: plain-text login (--skip-ssl)" refused \
    docker run --rm --network host -e MYSQL_PWD=$PW mariadb:11 mariadb --skip-ssl -h 127.0.0.1 -P ${PORT[mariadb]} -uroot -e 'SELECT 1'
  sec "MariaDB: TLS login, certificate verified" accepted \
    docker run --rm --network host -e MYSQL_PWD=$PW -v "$WORK/certs/ca.pem:/ca.pem:ro" mariadb:11 \
      mariadb --ssl --ssl-ca=/ca.pem --ssl-verify-server-cert -h 127.0.0.1 -P ${PORT[mariadb]} -uroot -e 'SELECT 1'
  sec "MySQL: plain-text login (--ssl-mode=DISABLED)" refused \
    docker run --rm --network host -e MYSQL_PWD=$PW mysql:8.4 mysql --ssl-mode=DISABLED --get-server-public-key -h 127.0.0.1 -P ${PORT[mysql]} -uroot -e 'SELECT 1'
  sec "MySQL: TLS login, certificate verified (VERIFY_IDENTITY)" accepted \
    docker run --rm --network host -e MYSQL_PWD=$PW -v "$WORK/certs/ca.pem:/ca.pem:ro" mysql:8.4 \
      mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca=/ca.pem -h 127.0.0.1 -P ${PORT[mysql]} -uroot -e 'SELECT 1'
  sec "MongoDB: plain-text login (no tls)" refused \
    docker run --rm --network host mongo:7 mongosh --quiet --serverSelectionTimeoutMS 4000 \
      "mongodb://root:$PW@127.0.0.1:${PORT[mongodb]}/?authSource=admin" --eval 'db.runCommand({ ping: 1 })'
  sec "MongoDB: TLS login, certificate verified" accepted \
    docker run --rm --network host -v "$WORK/certs/ca.pem:/ca.pem:ro" mongo:7 mongosh --quiet \
      "mongodb://root:$PW@127.0.0.1:${PORT[mongodb]}/?authSource=admin&tls=true&tlsCAFile=/ca.pem" --eval 'db.runCommand({ ping: 1 })'
  sec "MongoDB: TLS with a certificate from an UNTRUSTED CA" refused \
    docker run --rm --network host mongo:7 mongosh --quiet --serverSelectionTimeoutMS 4000 \
      "mongodb://root:$PW@127.0.0.1:${PORT[mongodb]}/?authSource=admin&tls=true" --eval 'db.runCommand({ ping: 1 })'

  log "security: db-migrate must refuse insecure settings"
  local c="$WORK/sec.conf"
  printf 'MIGRATION_NAME=sec\nSRC_ENGINE=postgres\nSRC_HOST=127.0.0.1\nSRC_PORT=%s\nSRC_USER=postgres\nSRC_DB=postgres\nTGT_HOST=127.0.0.1\nTGT_PORT=%s\nTGT_USER=postgres\nTGT_DB=postgres\nSAMPLE_SECONDS=0\nSTATE_DIR=%s\n' \
    "${PORT[postgres]}" "${PORT[postgres]}" "$WORK/runs/sec" > "$c"
  sec "db-migrate: SRC_SSL=disable without ALLOW_INSECURE_TRANSPORT" refused \
    env SRC_PASSWORD=$PW TGT_PASSWORD=$PW SRC_SSL=disable "$ROOT/db-migrate" assess "$c"
  sec "db-migrate: SRC_SSL=prefer (could fall back to plain text)" refused \
    env SRC_PASSWORD=$PW TGT_PASSWORD=$PW SRC_SSL=prefer "$ROOT/db-migrate" assess "$c"
  sec "db-migrate: SRC_SSL=verify without a CA" refused \
    env SRC_PASSWORD=$PW TGT_PASSWORD=$PW SRC_SSL=verify "$ROOT/db-migrate" assess "$c"
  sec "db-migrate: verify against the WRONG CA (impostor server)" refused \
    env SRC_PASSWORD=$PW TGT_PASSWORD=$PW SRC_SSL=verify SRC_SSL_CA="$WORK/certs/other-ca.pem" "$ROOT/db-migrate" assess "$c"
  sec "db-migrate: verify against the RIGHT CA" accepted \
    env SRC_PASSWORD=$PW TGT_PASSWORD=$PW SRC_SSL=verify SRC_SSL_CA="$WORK/certs/ca.pem" TGT_SSL=verify TGT_SSL_CA="$WORK/certs/ca.pem" "$ROOT/db-migrate" assess "$c"
}

# ── the dataset ─────────────────────────────────────────────────────────────

seed() {
  log "seeding $N rows per engine"
  pgq postgres "DROP DATABASE IF EXISTS src" >/dev/null; pgq postgres "CREATE DATABASE src" >/dev/null
  docker exec -i "$C_PG" psql -U postgres -d src -q -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE people (
  id serial PRIMARY KEY, name text, active boolean NOT NULL DEFAULT false,
  amount numeric(12,2), ratio real, score double precision,
  created timestamp, data jsonb, bin bytea, big bigint, status varchar(20) DEFAULT 'new');
CREATE TABLE orders (id serial PRIMARY KEY, person_id int NOT NULL REFERENCES people(id), total numeric(10,2));
CREATE INDEX orders_person ON orders (person_id);
CREATE TABLE tags (person_id int REFERENCES people(id), tag varchar(30), PRIMARY KEY (person_id, tag));
INSERT INTO people (name, active, amount, ratio, score, created, data, bin, big)
SELECT CASE id % 9 WHEN 0 THEN NULL WHEN 1 THEN E'O\\'Brien \\\\ back' WHEN 2 THEN E'line1\\nline2\\ttab'
         WHEN 3 THEN 'Ünïcödé 日本 🎉' WHEN 4 THEN 'quote "dq"' WHEN 5 THEN '<html>&amp;'
         WHEN 6 THEN 'trailing space ' WHEN 7 THEN '' ELSE 'plain' || id END,
       id % 2 = 0, id * 1.25, id / 7.0, id / 3.0,
       TIMESTAMP '2024-01-01' + (id * 1.5) * interval '1 second',
       jsonb_build_object('k', id, 'q', 'it''s "x"'),
       CASE WHEN id % 3 = 0 THEN decode('00ff275c0a' || lpad(to_hex(id % 256), 2, '0'), 'hex') END,
       id * 1000000007::bigint
FROM generate_series(1, $N) id;
INSERT INTO orders (person_id, total) SELECT 1 + g % $N, g % 100 + 0.5 FROM generate_series(1, $N * 3) g;
INSERT INTO tags SELECT g, 't' || (g % 3) FROM generate_series(1, $N / 2) g;
CREATE VIEW v_active AS SELECT id, name FROM people WHERE active;
CREATE FUNCTION spend(int) RETURNS numeric LANGUAGE sql AS \$\$ SELECT sum(total) FROM orders WHERE person_id = \$1 \$\$;
SQL

  local e
  for e in mariadb mysql; do
    myq $e "" "DROP DATABASE IF EXISTS src; CREATE DATABASE src CHARACTER SET utf8mb4" >/dev/null
    local depth="SET SESSION max_recursive_iterations = 1000000;"
    [ $e = mysql ] && depth="SET SESSION cte_max_recursion_depth = 1000000;"
    myq $e src "$depth
CREATE TABLE people (
  id INT AUTO_INCREMENT PRIMARY KEY, name TEXT, active TINYINT(1) NOT NULL DEFAULT 0,
  amount DECIMAL(12,2), ratio FLOAT, score DOUBLE, created DATETIME(6), data JSON, bin LONGBLOB,
  big BIGINT, status VARCHAR(20) DEFAULT 'new', size ENUM('S','M','L') DEFAULT 'M',
  touched TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP) ENGINE=InnoDB;
CREATE TABLE orders (id INT AUTO_INCREMENT PRIMARY KEY, person_id INT NOT NULL, total DECIMAL(10,2),
  KEY orders_person (person_id), CONSTRAINT fk_person FOREIGN KEY (person_id) REFERENCES people(id));
CREATE TABLE tags (person_id INT, tag VARCHAR(30), PRIMARY KEY (person_id, tag),
  CONSTRAINT fk_tag_person FOREIGN KEY (person_id) REFERENCES people(id));
INSERT INTO people (name, active, amount, ratio, score, created, data, bin, big, size)
WITH RECURSIVE s(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM s WHERE id < $N)
SELECT CASE id % 9 WHEN 0 THEN NULL WHEN 1 THEN 'O\\'Brien \\\\ back' WHEN 2 THEN CONCAT('line1', CHAR(10), 'line2', CHAR(9), 'tab')
         WHEN 3 THEN 'Ünïcödé 日本 🎉' WHEN 4 THEN 'quote \"dq\"' WHEN 5 THEN '<html>&amp;'
         WHEN 6 THEN 'trailing space ' WHEN 7 THEN '' ELSE CONCAT('plain', id) END,
       id % 2 = 0, id * 1.25, id / 7, id / 3,
       TIMESTAMPADD(MICROSECOND, id * 1500000, '2024-01-01 00:00:00'),
       JSON_OBJECT('k', id, 'q', 'it''s \"x\"'),
       IF(id % 3 = 0, UNHEX(CONCAT('00FF275C0A', LPAD(HEX(id % 256), 2, '0'))), NULL),
       id * 1000000007, ELT(1 + id % 3, 'S', 'M', 'L')
FROM s;
INSERT INTO orders (person_id, total)
WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < $N * 3)
SELECT 1 + g % $N, g % 100 + 0.5 FROM s;
INSERT INTO tags
WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < $N / 2)
SELECT g, CONCAT('t', g % 3) FROM s;
CREATE VIEW v_active AS SELECT id, name FROM people WHERE active = 1;
CREATE FUNCTION spend(p INT) RETURNS DECIMAL(12,2) READS SQL DATA RETURN (SELECT SUM(total) FROM orders WHERE person_id = p);" >/dev/null
  done

  mgjs src "d.dropDatabase();
    const names = i => [null, \"O'Brien \\\\ back\", 'line1\\nline2\\ttab', 'Ünïcödé 日本 🎉', 'quote \"dq\"', '<html>&amp;', 'trailing space ', '', 'plain' + i][i % 9];
    const docs = [];
    for (let i = 1; i <= $N; i++) {
      const hex = '00ff275c0a' + (i % 256).toString(16).padStart(2, '0');
      docs.push({ id: NumberInt(i), name: names(i), active: i % 2 === 0, amount: NumberDecimal((i * 1.25).toFixed(2)),
        ratio: i / 7, score: i / 3, created: new Date(Date.UTC(2024, 0, 1) + i * 1500),
        data: { k: i, q: 'it\\'s \"x\"' }, bin: i % 3 === 0 ? BinData(0, Buffer.from(hex, 'hex').toString('base64')) : null,
        big: NumberLong(String(i * 1000000007)) });
    }
    d.people.insertMany(docs);
    d.people.createIndex({ id: 1 }, { unique: true });
    d.orders.insertMany(Array.from({ length: $N * 3 }, (_, g) => ({ person_id: 1 + g % $N, total: NumberDecimal(String(g % 100 + 0.5)) })));
    d.createView('v_active', 'people', [{ \$match: { active: true } }]);" >/dev/null
}

# ── independent fingerprints ────────────────────────────────────────────────
# rows | md5 names | sum amount | active count | md5 binaries | md5 created | sum ratio

norm() { awk -F'|' 'BEGIN { OFS = "|" } { $3 = sprintf("%.2f", $3); $7 = sprintf("%.6f", $7); print }'; }

fp_pg() { # rows in real columns
  pgq "$1" "SELECT count(*), md5(coalesce(string_agg(coalesce(name, '~'), '|' ORDER BY id), '')), coalesce(sum(amount), 0),
    count(*) FILTER (WHERE active), md5(coalesce(string_agg(coalesce(encode(bin, 'hex'), '~'), '|' ORDER BY id), '')),
    md5(coalesce(string_agg(coalesce(to_char(created, 'YYYY-MM-DD HH24:MI:SS'), '~'), '|' ORDER BY id), '')),
    coalesce(sum(ratio::float8), 0) FROM people" | norm
}
fp_my() { # <engine> <db>
  myq "$1" "$2" "SET SESSION group_concat_max_len = 1073741824;
    SELECT COUNT(*), MD5(COALESCE(GROUP_CONCAT(COALESCE(name, '~') ORDER BY id SEPARATOR '|'), '')), COALESCE(SUM(amount), 0),
    COALESCE(SUM(active <> 0), 0), MD5(COALESCE(GROUP_CONCAT(COALESCE(LOWER(HEX(bin)), '~') ORDER BY id SEPARATOR '|'), '')),
    MD5(COALESCE(GROUP_CONCAT(COALESCE(DATE_FORMAT(created, '%Y-%m-%d %H:%i:%s'), '~') ORDER BY id SEPARATOR '|'), '')),
    COALESCE(SUM(ratio), 0) FROM people" | norm
}
fp_mongo() {
  mgjs "$1" "const c = require('crypto'); const md5 = s => c.createHash('md5').update(s, 'utf8').digest('hex');
    const num = v => (v !== null && typeof v === 'object') ? Number(v.toString()) : Number(v);
    const docs = d.people.find().toArray().sort((a, b) => num(a.id) - num(b.id));
    print([docs.length,
      md5(docs.map(x => x.name == null ? '~' : x.name).join('|')),
      docs.reduce((s, x) => s + (x.amount == null ? 0 : num(x.amount)), 0),
      docs.filter(x => x.active === true).length,
      md5(docs.map(x => x.bin == null ? '~' : x.bin.toString('hex')).join('|')),
      md5(docs.map(x => x.created == null ? '~' : x.created.toISOString().slice(0, 19).replace('T', ' ')).join('|')),
      docs.reduce((s, x) => s + (x.ratio == null ? 0 : num(x.ratio)), 0)].join('|'));" | norm
}
fp_pg_doc() { # MongoDB documents stored in a jsonb column
  pgq "$1" "SELECT count(*), md5(coalesce(string_agg(coalesce(doc->>'name', '~'), '|' ORDER BY (doc->>'id')::numeric), '')),
    coalesce(sum((doc->'amount'->>'\$numberDecimal')::numeric), 0), count(*) FILTER (WHERE (doc->>'active')::boolean),
    md5(coalesce(string_agg(coalesce(encode(decode(doc->'bin'->'\$binary'->>'base64', 'base64'), 'hex'), '~'), '|' ORDER BY (doc->>'id')::numeric), '')),
    md5(coalesce(string_agg(coalesce(replace(left(doc->'created'->>'\$date', 19), 'T', ' '), '~'), '|' ORDER BY (doc->>'id')::numeric), '')),
    coalesce(sum((doc->>'ratio')::float8), 0) FROM people" | norm
}
fp_my_doc() { # <engine> <db> — MongoDB documents stored in a JSON column
  local jv='CASE WHEN JSON_TYPE(JSON_EXTRACT(doc, @P)) = '\''NULL'\'' THEN NULL ELSE JSON_UNQUOTE(JSON_EXTRACT(doc, @P)) END'
  local name="${jv//@P/\'\$.name\'}" id="${jv//@P/\'\$.id\'}" amt="${jv//@P/\'\$.amount.\"\$numberDecimal\"\'}"
  local act="${jv//@P/\'\$.active\'}" bin="${jv//@P/\'\$.bin.\"\$binary\".base64\'}" cr="${jv//@P/\'\$.created.\"\$date\"\'}"
  local rat="${jv//@P/\'\$.ratio\'}"
  myq "$1" "$2" "SET SESSION group_concat_max_len = 1073741824;
    SELECT COUNT(*), MD5(COALESCE(GROUP_CONCAT(COALESCE($name, '~') ORDER BY CAST($id AS DECIMAL(20,0)) SEPARATOR '|'), '')),
    COALESCE(SUM(CAST($amt AS DECIMAL(20,2))), 0), COALESCE(SUM($act = 'true'), 0),
    MD5(COALESCE(GROUP_CONCAT(COALESCE(LOWER(HEX(FROM_BASE64($bin))), '~') ORDER BY CAST($id AS DECIMAL(20,0)) SEPARATOR '|'), '')),
    MD5(COALESCE(GROUP_CONCAT(COALESCE(REPLACE(LEFT($cr, 19), 'T', ' '), '~') ORDER BY CAST($id AS DECIMAL(20,0)) SEPARATOR '|'), '')),
    COALESCE(SUM(CAST($rat AS DOUBLE)), 0) FROM people" | norm
}

fingerprint() { # <engine> <db> <shape: rows|docs>
  case "$1/$3" in
    postgres/rows) fp_pg "$2" ;; postgres/docs) fp_pg_doc "$2" ;;
    mariadb/rows|mysql/rows) fp_my "$1" "$2" ;; mariadb/docs|mysql/docs) fp_my_doc "$1" "$2" ;;
    mongodb/*) fp_mongo "$2" ;;
  esac
}

# ── one direction ───────────────────────────────────────────────────────────

drop_target() { # <engine> <db>
  case "$1" in
    postgres) pgq postgres "DROP DATABASE IF EXISTS $2 WITH (FORCE)" >/dev/null; pgq postgres "CREATE DATABASE $2" >/dev/null ;;
    mariadb|mysql) myq "$1" "" "DROP DATABASE IF EXISTS $2" >/dev/null ;;
    mongodb) mgjs "$2" "d.dropDatabase()" >/dev/null ;;
  esac
}

declare -a ROWS=()
run_pair() {
  local s="$1" t="$2" name="e2e_${1}_to_${2}" db="t_${1}_${2}" conf rc_tool=0 t0 secs shape=rows
  conf="$WORK/$name.conf"
  [ "$s" = mongodb ] && [ "$t" != mongodb ] && shape=docs
  log "$s → $t"
  drop_target "$t" "$db"
  cat > "$conf" <<EOF
MIGRATION_NAME=$name
SRC_ENGINE=$s
SRC_HOST=127.0.0.1
SRC_PORT=${PORT[$s]}
SRC_USER=${USER_OF[$s]}
SRC_DB=src
SRC_SSL=verify
SRC_SSL_CA=$WORK/certs/ca.pem
TGT_ENGINE=$t
TGT_HOST=127.0.0.1
TGT_PORT=${PORT[$t]}
TGT_USER=${USER_OF[$t]}
TGT_DB=$db
TGT_SSL=verify
TGT_SSL_CA=$WORK/certs/ca.pem
DOWNTIME_MINUTES=600
SAMPLE_SECONDS=0
STATE_DIR=$WORK/runs/$name
EOF
  rm -rf "$WORK/runs/$name"
  t0="$(date +%s)"
  (
    export SRC_PASSWORD=$PW TGT_PASSWORD=$PW
    "$ROOT/db-migrate" assess "$conf" && "$ROOT/db-migrate" plan "$conf" && "$ROOT/db-migrate" run "$conf" --checksum
  ) > "$WORK/$name.log" 2>&1 || rc_tool=$?
  secs=$(( $(date +%s) - t0 ))
  local fs ft verdict tool
  fs="$(fingerprint "$s" src rows 2>&1 | tail -1)"
  ft="$(fingerprint "$t" "$db" "$shape" 2>&1 | tail -1)"
  tool="$( [ $rc_tool = 0 ] && echo PASS || echo "FAIL (exit $rc_tool)" )"
  # What the SERVERS reported for the tool's own sessions (from assess).
  local tls_s tls_t tls
  tls_s="$( ( . "$WORK/runs/$name/assessment.env" 2>/dev/null; echo "${SRC_TLS:-none}" ) )"
  tls_t="$( ( . "$WORK/runs/$name/assessment.env" 2>/dev/null; echo "${TGT_TLS:-none}" ) )"
  tls="$(short_tls "$tls_s") / $(short_tls "$tls_t")"
  if [ "$fs" = "$ft" ] && [ $rc_tool = 0 ] && [ "$tls_s" != none ] && [ "$tls_t" != none ]; then verdict="✅"; else verdict="❌"; fi
  printf '  tool: %s   tls: %s\n  source: %s\n  target: %s   %s\n' "$tool" "$tls" "$fs" "$ft" "$verdict"
  [ $rc_tool = 0 ] || tail -5 "$WORK/$name.log" | sed 's/^/    | /'
  local kind
  if [ "$s" = "$t" ]; then kind="native dump"; else kind="converted"; fi
  ROWS+=("| $s → $t | $kind | $tool | $( [ "$fs" = "$ft" ] && echo "identical" || echo "**differs**" ) | $tls | ${secs}s | $verdict |")
  [ "$fs" = "$ft" ] || ROWS+=("|   ↳ source \`$fs\` / target \`$ft\` | | | | | | |")
}

short_tls() { # "TLSv1.3 TLS_AES_256_GCM_SHA384" → "TLSv1.3"; MongoDB's client-side evidence → "TLS ✓cert"
  case "$1" in
    none) echo "**none**" ;;
    TLS\ \(enforced*) echo "TLS, cert verified" ;;
    *) echo "${1%% *}" ;;
  esac
}

# ── main ────────────────────────────────────────────────────────────────────

mkdir -p "$WORK"
start
security_checks
seed
if [ $# -eq 2 ]; then
  run_pair "$1" "$2"
else
  for s in "${ENGINES[@]}"; do for t in "${ENGINES[@]}"; do run_pair "$s" "$t"; done; done
fi

{
  echo "# End-to-end results"
  echo
  echo "Generated $(date -u +%FT%TZ) by \`tests/e2e.sh\` — PostgreSQL 16, MariaDB 11, MySQL 8.4, MongoDB 7, $N rows."
  echo
  echo "**Tool** = db-migrate's own assess → plan → run → validate (--checksum). **Data** = an independent"
  echo "fingerprint computed by the source and target engines themselves: row count, MD5 of every text value,"
  echo "MD5 of every binary value, MD5 of every timestamp, sum of the decimal column, count of true booleans,"
  echo "sum of the single-precision float column. **TLS** = the protocol the source / target SERVER reported"
  echo "for the tool's own sessions. Every connection ran with \`verify\` (encrypted + certificate and hostname"
  echo "checked against a CA) against servers that refuse plain text. All three must hold for ✅."
  echo
  echo "## Migrations"
  echo
  echo "| Direction | Method | Tool | Data | TLS (src / tgt) | Time | |"
  echo "|---|---|---|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
  echo "## Encryption in transit"
  echo
  echo "| Check | Result | |"
  echo "|---|---|---|"
  printf '%s\n' "${SEC[@]}"
} > "$HERE/RESULTS.md"
log "results: tests/RESULTS.md"
grep -E '^\| [a-z]' "$HERE/RESULTS.md" | sed 's/^/  /'

[ "${KEEP:-0}" = 1 ] || docker rm -f "$C_PG" "$C_MARIA" "$C_MYSQL" "$C_MONGO" >/dev/null
! grep -q '❌' "$HERE/RESULTS.md"
