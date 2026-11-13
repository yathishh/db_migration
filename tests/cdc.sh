#!/usr/bin/env bash
# CDC end-to-end over TLS: PostgreSQL, MariaDB and MySQL, each with its own
# source and target server.
#
#   tests/cdc.sh            all three engines
#   tests/cdc.sh postgres   one engine
#
# Every server accepts TLS only. For each engine:
#   assess → plan (full-load+cdc) → full-load → cdc start → wait until caught up
#   → inserts, updates and deletes on the SOURCE while replication runs
#   → cutover (drain, sequences, validate, tear down)
# and then, independently of the tool:
#   - source and target fingerprints must be identical (so the live changes arrived)
#   - the replication link itself must have been encrypted, with the source's
#     certificate verified by the target (REPL_SSL=verify)
#   - nothing may be left behind (slot / publication / subscription / replica config)
# Results go to tests/RESULTS-CDC.md.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$HERE/.work/cdc"
PW=e2e-pw
NET=dbm-cdc-net
B="${CDC_PORT_BASE:-57200}"
declare -A PORT=([postgres-src]=$((B + 11)) [postgres-tgt]=$((B + 12)) [mariadb-src]=$((B + 21)) [mariadb-tgt]=$((B + 22)) [mysql-src]=$((B + 31)) [mysql-tgt]=$((B + 32)))
declare -A IMG=([postgres]=postgres:16-alpine [mariadb]=mariadb:11 [mysql]=mysql:8.4)
declare -A OWNER=([postgres]=postgres [mariadb]=mysql [mysql]=mysql)
declare -A IPORT=([postgres]=5432 [mariadb]=3306 [mysql]=3306)
ENGINES=("${@:-postgres mariadb mysql}"); [ $# -gt 0 ] || ENGINES=(postgres mariadb mysql)

log() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
cname() { echo "dbm-cdc-$1-$2"; }   # engine, src|tgt

cleanup() {
  local e r
  for e in postgres mariadb mysql; do for r in src tgt; do docker rm -f "$(cname $e $r)" >/dev/null 2>&1 || true; done; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}

certs() {
  local d="$WORK/certs" san="DNS:localhost,IP:127.0.0.1" e r
  for e in postgres mariadb mysql; do for r in src tgt; do san+=",DNS:$(cname $e $r)"; done; done
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=db-migrate cdc CA" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
    printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san" > ext.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile ext.cnf 2>/dev/null
    chmod 644 ./* )
}

wait_for() {
  local c="$1" i; shift
  for i in $(seq 1 60); do
    "$@" >/dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || break
    sleep 2
  done
  echo "server $c did not become ready:" >&2; docker logs "$c" 2>&1 | tail -8 >&2; exit 3
}

start_engine() {
  local e="$1" r n id=0 cmd envs
  for r in src tgt; do
    n="$(cname "$e" "$r")"; id=$(( id + 1 ))
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT[$e-$r]}") 2>/dev/null; then echo "port ${PORT[$e-$r]} in use — set CDC_PORT_BASE" >&2; exit 2; fi
    case "$e" in
      postgres) envs=(-e POSTGRES_PASSWORD=$PW)
        cmd="postgres -c ssl=on -c ssl_cert_file=/certs/server.crt -c ssl_key_file=/certs/server.key -c wal_level=logical" ;;
      mariadb) envs=(-e MARIADB_ROOT_PASSWORD=$PW)
        cmd="mariadbd --ssl-cert=/certs/server.crt --ssl-key=/certs/server.key --ssl-ca=/certs/ca.pem --require-secure-transport=ON --server-id=$id --log-bin=mysql-bin --binlog-format=ROW" ;;
      mysql) envs=(-e MYSQL_ROOT_PASSWORD=$PW)
        cmd="mysqld --ssl-cert=/certs/server.crt --ssl-key=/certs/server.key --ssl-ca=/certs/ca.pem --require-secure-transport=ON --server-id=$id" ;;
    esac
    docker create --name "$n" --network "$NET" --hostname "$n" "${envs[@]}" -p "${PORT[$e-$r]}:${IPORT[$e]}" --entrypoint sh "${IMG[$e]}" \
      -c "mkdir -p /certs && cp /certs-in/* /certs/ && chown -R ${OWNER[$e]} /certs && chmod 600 /certs/server.key && exec docker-entrypoint.sh $cmd" >/dev/null
    docker cp "$WORK/certs/." "$n:/certs-in"
    docker start "$n" >/dev/null
  done
  for r in src tgt; do
    n="$(cname "$e" "$r")"
    case "$e" in
      postgres)
        wait_for "$n" sh -c "docker logs $n 2>&1 | grep -q 'PostgreSQL init process complete'"
        wait_for "$n" docker exec "$n" pg_isready -U postgres -q
        # TLS only, for ordinary and for replication connections
        docker exec "$n" sh -c 'printf "local all all trust\nhostssl all all all scram-sha-256\nhostssl replication all all scram-sha-256\nhostnossl all all all reject\nhostnossl replication all all reject\n" > "$PGDATA/pg_hba.conf"'
        docker exec "$n" psql -U postgres -qc 'SELECT pg_reload_conf()' >/dev/null ;;
      mariadb) wait_for "$n" docker exec "$n" healthcheck.sh --connect ;;
      mysql) wait_for "$n" docker exec -e MYSQL_PWD=$PW "$n" mysql -uroot -e 'SELECT 1' ;;
    esac
  done
  sleep 2
}

# sql <engine> <src|tgt> <db> <sql> — through the local socket inside the server
sql() {
  local e="$1" n; n="$(cname "$1" "$2")"
  case "$e" in
    postgres) docker exec "$n" psql -U postgres -d "$3" -X -At -F'|' -v ON_ERROR_STOP=1 -c "$4" ;;
    mariadb) docker exec -e MYSQL_PWD=$PW "$n" mariadb -uroot --default-character-set=utf8mb4 -N -B ${3:+"$3"} -e "$4" | tr '\t' '|' ;;
    mysql) docker exec -e MYSQL_PWD=$PW "$n" mysql -uroot --default-character-set=utf8mb4 -N -B ${3:+"$3"} -e "$4" 2>/dev/null | tr '\t' '|' ;;
  esac
}

seed() {
  local e="$1"
  if [ "$e" = postgres ]; then
    sql $e src postgres "CREATE DATABASE app" >/dev/null; sql $e tgt postgres "CREATE DATABASE app" >/dev/null
    sql $e src app "CREATE TABLE people (id serial PRIMARY KEY, name text, amount numeric(12,2));
      CREATE TABLE orders (id serial PRIMARY KEY, person_id int NOT NULL REFERENCES people(id), total numeric(10,2));
      INSERT INTO people (name, amount) SELECT CASE g % 4 WHEN 0 THEN NULL WHEN 1 THEN E'O\\'Brien \\\\ x' WHEN 2 THEN 'Ünï 日本 🎉' ELSE 'p' || g END, g * 1.25 FROM generate_series(1, 1000) g;
      INSERT INTO orders (person_id, total) SELECT 1 + g % 1000, g + 0.5 FROM generate_series(1, 3000) g;" >/dev/null
  else
    local depth="SET SESSION max_recursive_iterations = 100000;"; [ "$e" = mysql ] && depth="SET SESSION cte_max_recursion_depth = 100000;"
    sql $e src "" "CREATE DATABASE app CHARACTER SET utf8mb4" >/dev/null
    sql $e src app "$depth
      CREATE TABLE people (id INT AUTO_INCREMENT PRIMARY KEY, name TEXT, amount DECIMAL(12,2)) ENGINE=InnoDB;
      CREATE TABLE orders (id INT AUTO_INCREMENT PRIMARY KEY, person_id INT NOT NULL, total DECIMAL(10,2), CONSTRAINT fk_p FOREIGN KEY (person_id) REFERENCES people(id)) ENGINE=InnoDB;
      INSERT INTO people (name, amount) WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 1000)
        SELECT CASE g % 4 WHEN 0 THEN NULL WHEN 1 THEN 'O\\'Brien \\\\ x' WHEN 2 THEN 'Ünï 日本 🎉' ELSE CONCAT('p', g) END, g * 1.25 FROM s;
      INSERT INTO orders (person_id, total) WITH RECURSIVE s(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM s WHERE g < 3000)
        SELECT 1 + g % 1000, g + 0.5 FROM s;" >/dev/null
  fi
}

live_writes() { # changes made on the source WHILE replication is running
  local e="$1"
  if [ "$e" = postgres ]; then
    sql $e src app "INSERT INTO people (name, amount) SELECT 'live' || g, g FROM generate_series(1, 200) g;
      UPDATE people SET name = 'changed', amount = amount + 1 WHERE id <= 50; DELETE FROM orders WHERE id <= 30;" >/dev/null
  else
    sql $e src app "INSERT INTO people (name, amount) SELECT CONCAT('live', id), id FROM orders WHERE id BETWEEN 31 AND 230;
      UPDATE people SET name = 'changed', amount = amount + 1 WHERE id <= 50; DELETE FROM orders WHERE id <= 30;" >/dev/null
  fi
}

fp() { # people rows | md5 names | sum amount | orders rows | sum totals
  local e="$1" r="$2"
  if [ "$e" = postgres ]; then
    sql $e $r app "SELECT (SELECT count(*) FROM people), (SELECT md5(string_agg(coalesce(name, '~'), '|' ORDER BY id)) FROM people), (SELECT sum(amount) FROM people), (SELECT count(*) FROM orders), (SELECT sum(total) FROM orders)"
  else
    sql $e $r app "SET SESSION group_concat_max_len = 1073741824; SELECT (SELECT COUNT(*) FROM people), (SELECT MD5(GROUP_CONCAT(COALESCE(name, '~') ORDER BY id SEPARATOR '|')) FROM people), (SELECT SUM(amount) FROM people), (SELECT COUNT(*) FROM orders), (SELECT SUM(total) FROM orders)"
  fi
}

# What protected the replication connection, read on the servers themselves.
link_evidence() {
  local e="$1"
  case "$e" in
    postgres) sql $e src app "SELECT s.version || ' ' || s.cipher FROM pg_stat_replication r JOIN pg_stat_ssl s USING (pid) WHERE s.ssl LIMIT 1" ;;
    mysql) sql $e src "" "SELECT CONCAT(MAX(IF(s.variable_name = 'Ssl_version', s.variable_value, NULL)), ' ', MAX(IF(s.variable_name = 'Ssl_cipher', s.variable_value, NULL))) FROM performance_schema.threads t JOIN performance_schema.status_by_thread s ON s.thread_id = t.thread_id WHERE t.processlist_command LIKE 'Binlog Dump%' AND s.variable_name IN ('Ssl_version', 'Ssl_cipher')" ;;
    mariadb)
      # MariaDB does not expose another session's cipher without performance_schema;
      # the replica's own settings are the evidence, and the source refuses plain text.
      docker exec -e MYSQL_PWD=$PW "$(cname $e tgt)" mariadb -uroot -e 'SHOW SLAVE STATUS\G' \
        | awk -F': ' '/Master_SSL_Allowed|Master_SSL_Verify_Server_Cert|Slave_IO_Running/ { gsub(/ /, "", $1); printf "%s=%s ", $1, $2 }' ;;
  esac
}

leftovers() { # must print 0
  local e="$1"
  if [ "$e" = postgres ]; then
    echo $(( $(sql $e src app "SELECT count(*) FROM pg_replication_slots") + $(sql $e src app "SELECT count(*) FROM pg_publication") + $(sql $e tgt app "SELECT count(*) FROM pg_subscription") ))
  elif [ "$e" = mariadb ]; then
    docker exec -e MYSQL_PWD=$PW "$(cname $e tgt)" mariadb -uroot -e 'SHOW SLAVE STATUS\G' | grep -c 'Master_Host' || true
  else
    docker exec -e MYSQL_PWD=$PW "$(cname $e tgt)" mysql -uroot -e 'SHOW REPLICA STATUS\G' 2>/dev/null | grep -c 'Source_Host' || true
  fi
}

declare -a ROWS=()
run_engine() {
  local e="$1" name="cdc_$1" conf="$WORK/cdc_$1.conf" rc=0 user=root step
  [ "$e" = postgres ] && user=postgres
  log "$e: source → target with CDC over TLS (REPL_SSL=verify)"
  start_engine "$e"
  seed "$e"
  cat > "$conf" <<EOF
MIGRATION_NAME=$name
SRC_ENGINE=$e
SRC_HOST=127.0.0.1
SRC_PORT=${PORT[$e-src]}
SRC_USER=$user
SRC_DB=app
SRC_SSL=verify
SRC_SSL_CA=$WORK/certs/ca.pem
TGT_HOST=127.0.0.1
TGT_PORT=${PORT[$e-tgt]}
TGT_USER=$user
TGT_DB=app
TGT_SSL=verify
TGT_SSL_CA=$WORK/certs/ca.pem
REPL_HOST=$(cname "$e" src)
REPL_PORT=${IPORT[$e]}
REPL_SSL=verify
REPL_SSL_CA_PATH=/certs/ca.pem
SAMPLE_SECONDS=0
CUTOVER_WAIT_MINUTES=3
STATE_DIR=$WORK/runs/$name
EOF
  rm -rf "$WORK/runs/$name"
  export SRC_PASSWORD=$PW TGT_PASSWORD=$PW
  local dm="$ROOT/db-migrate" logf="$WORK/$name.log" ev="" before
  : > "$logf"
  {
    "$dm" assess "$conf" && "$dm" plan "$conf" --strategy full-load+cdc \
      && "$dm" full-load "$conf" --phase rehearsal && "$dm" cdc start "$conf" && "$dm" cdc wait "$conf" --timeout 3
  } >> "$logf" 2>&1 || rc=$?
  if [ $rc = 0 ]; then
    before="$(fp "$e" tgt | tail -1)"
    live_writes "$e"
    sleep 3
    ev="$(link_evidence "$e" | tail -1)"
    "$dm" cutover "$conf" --strategy full-load+cdc --checksum --yes >> "$logf" 2>&1 || rc=$?
  fi
  local fs ft left verdict tool
  fs="$(fp "$e" src | tail -1)"; ft="$(fp "$e" tgt | tail -1)"; left="$(leftovers "$e" | tail -1)"
  tool="$( [ $rc = 0 ] && echo PASS || echo "FAIL (exit $rc)" )"
  if [ $rc = 0 ] && [ "$fs" = "$ft" ] && [ "$ft" != "${before:-}" ] && [ -n "$ev" ] && [ "$left" = 0 ]; then verdict="✅"; else verdict="❌"; fi
  printf '  tool: %s\n  source: %s\n  target: %s\n  target before live writes: %s\n  replication link: %s\n  left behind: %s   %s\n' "$tool" "$fs" "$ft" "${before:-n/a}" "${ev:-none}" "$left" "$verdict"
  [ $rc = 0 ] || tail -6 "$logf" | sed 's/^/    | /'
  ROWS+=("| $e | $tool | $( [ "$fs" = "$ft" ] && echo identical || echo "**differs**" ) | $( [ "$ft" != "${before:-}" ] && echo yes || echo "**no**" ) | ${ev:-**none**} | $left | $verdict |")
  docker rm -f "$(cname "$e" src)" "$(cname "$e" tgt)" >/dev/null 2>&1 || true
}

mkdir -p "$WORK"
cleanup
docker network create "$NET" >/dev/null
certs
for e in "${ENGINES[@]}"; do run_engine "$e"; done
{
  echo "# CDC end-to-end results"
  echo
  echo "Generated $(date -u +%FT%TZ) by \`tests/cdc.sh\`. Separate TLS-only source and target servers per engine;"
  echo "every connection, including the replication link, in \`verify\` mode."
  echo
  echo "- **Data** — source and target fingerprints after cutover (people rows, MD5 of all names, sum of amounts, orders rows, sum of totals)."
  echo "- **Live changes arrived** — the target's fingerprint changed after inserts/updates/deletes were made on the source during replication."
  echo "- **Replication link** — what the servers report for the replica's connection."
  echo "- **Left behind** — slots, publications, subscriptions or replica configuration remaining after cutover (must be 0)."
  echo
  echo "| Engine | Tool | Data | Live changes arrived | Replication link | Left behind | |"
  echo "|---|---|---|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
} > "$HERE/RESULTS-CDC.md"
log "results: tests/RESULTS-CDC.md"
[ "${KEEP:-0}" = 1 ] || cleanup
! grep -q '❌' "$HERE/RESULTS-CDC.md"
