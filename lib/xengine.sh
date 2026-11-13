# shellcheck shell=bash
# Cross-engine (heterogeneous) migrations — sourced by db-migrate.
#
#   postgres  ⇄ mariadb / mysql     schema converted, data transformed in flight
#   postgres / mariadb / mysql → mongodb   one document per row (typed: dates,
#                                          longs, decimals, binary)
#   mongodb → postgres / mariadb / mysql   one row per document: _id + the whole
#                                          document in a JSON column (lossless)
#
# What is converted automatically: tables, column types, NOT NULL, defaults
# that have an equivalent, auto-increment / identity, primary keys, unique and
# plain indexes, foreign keys.
#
# What is NOT: views, functions, procedures, triggers, events, check
# constraints and MongoDB validators. They are code written in one engine's
# dialect; translating them mechanically produces SQL that runs and is wrong.
# They are exported to xengine/manual_objects.* and listed in conversion.md.
#
# Data never touches disk: the source engine formats each row in exactly the
# shape the target's bulk loader reads, and it is streamed straight in:
#   mysql → postgres   SELECT CONCAT_WS(tab, …)  →  COPY … FROM STDIN (text)
#   postgres → mysql   SELECT '(lit, lit, …)'    →  batched multi-row INSERT
#   * → mongodb        one Extended-JSON line    →  mongoimport
#   mongodb → *        mongoexport (relaxed)     →  COPY / INSERT into a JSON column

is_xengine() { ! homogeneous && ! same_family; }
is_my()      { case "$1" in mariadb|mysql) return 0;; esac; return 1; }

pg_id() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
my_id() { local s="${1//\`/\`\`}"; printf '`%s`' "$s"; }

x_init() {
  X="$STATE/xengine"; mkdir -p "$X"
  TGT_SCHEMA="${TGT_SCHEMA:-public}"
  valid TGT_SCHEMA "$TGT_SCHEMA" '^[A-Za-z0-9_]+$'
  TINYINT1_AS_BOOL="${TINYINT1_AS_BOOL:-true}"
  MYSQL_TGT_COLLATION="${MYSQL_TGT_COLLATION:-utf8mb4_bin}"
  valid MYSQL_TGT_COLLATION "$MYSQL_TGT_COLLATION" '^[A-Za-z0-9_]+$'
}

x_tgt_ref() {
  case "$TGT_ENGINE" in
    postgres) printf '%s.%s' "$(pg_id "$TGT_SCHEMA")" "$(pg_id "$1")" ;;
    mariadb|mysql) my_id "$1" ;;
    mongodb) printf '%s' "$1" ;;
  esac
}

xwarn() { printf '%s\n' "$*" >> "$X/warnings.txt"; }

# ── SQL templates (quoted heredocs: no shell escaping inside) ───────────────
# @V is replaced by a column expression.

# PostgreSQL → a MySQL string literal on one line (backslash escapes, so the
# row never spans lines and the batching below can work line by line).
read -r -d '' TPL_PG_MYLIT <<'SQL' || true
'''' || replace(replace(replace(replace(@V, '\', '\\'), '''', '\'''), chr(10), '\n'), chr(13), '\r') || ''''
SQL
# MySQL → one field of PostgreSQL COPY text format.
read -r -d '' TPL_MY_COPYESC <<'SQL' || true
REPLACE(REPLACE(REPLACE(REPLACE(@V, '\\', '\\\\'), '\t', '\\t'), '\n', '\\n'), '\r', '\\r')
SQL
read -r -d '' TPL_MY_NULL <<'SQL' || true
IFNULL(@V, '\\N')
SQL
read -r -d '' TPL_MY_HEX <<'SQL' || true
CONCAT('\\\\x', HEX(@V))
SQL
read -r -d '' TPL_MY_B64 <<'SQL' || true
REPLACE(TO_BASE64(@V), '\n', '')
SQL

tpl() { local t="$1"; printf '%s' "${t//@V/$2}"; }

# ── 1. extract the source catalog into a neutral form ───────────────────────
#
# columns.txt  srcref|table|column|gtype|len|prec|scale|nullable|autoinc|srctype|default
# pk.txt       table|col,col
# indexes.txt  table|name|unique|col,col|skip-reason
# fks.txt      table|name|cols|reftable|refcols|on_delete|on_update
# tables.txt   table   (load order irrelevant: FKs are added after the data)
#
# gtype is the neutral type: int2 int4 int8 uint8 dec float4 float8 bool bit
# char varchar text bytes date time ts tstz json array uuid enum geom money
# interval other

x_extract_pg() {
  local sl; sl="$(pg_schema_list)"
  q src "SELECT format('%I.%I', c.table_schema, c.table_name), c.table_name, c.column_name,
      CASE
        WHEN c.data_type = 'smallint' THEN 'int2'
        WHEN c.data_type = 'integer' THEN 'int4'
        WHEN c.data_type = 'bigint' THEN 'int8'
        WHEN c.data_type = 'numeric' THEN 'dec'
        WHEN c.data_type = 'real' THEN 'float4'
        WHEN c.data_type = 'double precision' THEN 'float8'
        WHEN c.data_type = 'boolean' THEN 'bool'
        WHEN c.data_type = 'character' THEN 'char'
        WHEN c.data_type = 'character varying' THEN CASE WHEN c.character_maximum_length IS NULL THEN 'text' ELSE 'varchar' END
        WHEN c.data_type IN ('text', 'xml', 'name') THEN 'text'
        WHEN c.data_type = 'bytea' THEN 'bytes'
        WHEN c.data_type = 'date' THEN 'date'
        WHEN c.data_type IN ('time without time zone', 'time with time zone') THEN 'time'
        WHEN c.data_type = 'timestamp without time zone' THEN 'ts'
        WHEN c.data_type = 'timestamp with time zone' THEN 'tstz'
        WHEN c.data_type IN ('json', 'jsonb') THEN 'json'
        WHEN c.data_type = 'uuid' THEN 'uuid'
        WHEN c.data_type = 'ARRAY' THEN 'array'
        WHEN c.data_type = 'money' THEN 'money'
        WHEN c.data_type = 'interval' THEN 'interval'
        WHEN c.data_type = 'USER-DEFINED' AND EXISTS (SELECT 1 FROM pg_type t WHERE t.typname = c.udt_name AND t.typtype = 'e') THEN 'enum'
        ELSE 'other' END,
      coalesce(c.character_maximum_length, 0), coalesce(c.numeric_precision, 0), coalesce(c.numeric_scale, 0),
      CASE WHEN c.is_nullable = 'YES' THEN 'Y' ELSE 'N' END,
      CASE WHEN c.is_identity = 'YES' OR c.column_default LIKE 'nextval(%' THEN 'Y' ELSE 'N' END,
      CASE WHEN c.data_type IN ('USER-DEFINED', 'ARRAY') THEN c.udt_name ELSE c.data_type END
        || CASE WHEN c.is_generated = 'ALWAYS' THEN ' (generated)' ELSE '' END,
      coalesce(CASE WHEN c.column_default LIKE 'nextval(%' THEN NULL ELSE c.column_default END, '')
    FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
    WHERE c.table_schema IN ($sl)
    ORDER BY c.table_schema, c.table_name, c.ordinal_position" > "$X/columns.txt"

  q src "SELECT ct.relname, ci.relname, CASE WHEN ix.indisunique THEN 'Y' ELSE 'N' END,
      CASE WHEN ix.indisprimary THEN 'Y' ELSE 'N' END,
      string_agg(coalesce(a.attname, '?'), ',' ORDER BY k.ord),
      CASE WHEN ix.indexprs IS NOT NULL THEN 'expression index' WHEN ix.indpred IS NOT NULL THEN 'partial index'
           WHEN am.amname <> 'btree' THEN am.amname || ' index' ELSE '' END
    FROM pg_index ix
    JOIN pg_class ci ON ci.oid = ix.indexrelid
    JOIN pg_am am ON am.oid = ci.relam
    JOIN pg_class ct ON ct.oid = ix.indrelid
    JOIN pg_namespace n ON n.oid = ct.relnamespace
    CROSS JOIN LATERAL unnest(ix.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
    LEFT JOIN pg_attribute a ON a.attrelid = ct.oid AND a.attnum = k.attnum AND k.attnum > 0
    WHERE n.nspname IN ($sl) AND ct.relkind = 'r'
    GROUP BY ct.relname, ci.relname, ix.indisunique, ix.indisprimary, ix.indexprs IS NOT NULL, ix.indpred IS NOT NULL, am.amname
    ORDER BY 1, 2" > "$X/.idx"
  awk -F'|' '$4 == "Y" { print $1 "|" $5 }' "$X/.idx" > "$X/pk.txt"
  awk -F'|' 'BEGIN { OFS = "|" } $4 == "N" { print $1, $2, $3, $5, $6 }' "$X/.idx" > "$X/indexes.txt"
  rm -f "$X/.idx"

  q src "SELECT cl.relname, co.conname,
      (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(co.conkey) WITH ORDINALITY k(n, ord) JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.n),
      rc.relname,
      (SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(co.confkey) WITH ORDINALITY k(n, ord) JOIN pg_attribute a ON a.attrelid = co.confrelid AND a.attnum = k.n),
      CASE co.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END,
      CASE co.confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END
    FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace
    JOIN pg_class rc ON rc.oid = co.confrelid
    WHERE co.contype = 'f' AND n.nspname IN ($sl) ORDER BY 1, 2" > "$X/fks.txt"

  # Definitions that need a human: views, matviews, functions/procedures (not
  # from extensions), triggers, check constraints.
  q src "SELECT '-- VIEW ' || format('%I.%I', schemaname, viewname) || chr(10) || 'CREATE VIEW ' || format('%I.%I', schemaname, viewname) || ' AS' || chr(10) || definition || chr(10) FROM pg_views WHERE schemaname IN ($sl)
    UNION ALL SELECT '-- MATERIALIZED VIEW ' || format('%I.%I', schemaname, matviewname) || chr(10) || 'CREATE MATERIALIZED VIEW ' || format('%I.%I', schemaname, matviewname) || ' AS' || chr(10) || definition || chr(10) FROM pg_matviews WHERE schemaname IN ($sl)
    UNION ALL SELECT '-- FUNCTION ' || p.oid::regprocedure::text || chr(10) || pg_get_functiondef(p.oid) || ';' || chr(10) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ($sl) AND p.prokind IN ('f', 'p') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
    UNION ALL SELECT '-- TRIGGER ' || t.tgname || ' ON ' || c.relname || chr(10) || pg_get_triggerdef(t.oid) || ';' || chr(10) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT t.tgisinternal AND n.nspname IN ($sl)
    UNION ALL SELECT '-- CHECK ' || co.conname || ' ON ' || cl.relname || chr(10) || 'ALTER TABLE ' || cl.relname || ' ADD CONSTRAINT ' || co.conname || ' ' || pg_get_constraintdef(co.oid) || ';' || chr(10)
      FROM pg_constraint co JOIN pg_class cl ON cl.oid = co.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE co.contype = 'c' AND n.nspname IN ($sl)" > "$X/manual_objects.sql"
}

x_extract_my() {
  local tinybool="'bool'"
  [ "$TINYINT1_AS_BOOL" = true ] || tinybool="'int2'"
  # MySQL 8 shows tinyint(1) with its display width; MariaDB too.
  q src "SELECT CONCAT('\`', REPLACE(c.table_name, '\`', '\`\`'), '\`'), c.table_name, c.column_name,
      CASE
        WHEN c.column_type LIKE 'tinyint(1)%' AND c.column_type NOT LIKE '%unsigned%' THEN $tinybool
        WHEN c.data_type IN ('tinyint', 'smallint') AND c.column_type NOT LIKE '%unsigned%' THEN 'int2'
        WHEN c.data_type IN ('tinyint', 'smallint', 'mediumint') THEN 'int4'
        WHEN c.data_type = 'int' AND c.column_type NOT LIKE '%unsigned%' THEN 'int4'
        WHEN c.data_type = 'int' THEN 'int8'
        WHEN c.data_type = 'bigint' AND c.column_type NOT LIKE '%unsigned%' THEN 'int8'
        WHEN c.data_type = 'bigint' THEN 'uint8'
        WHEN c.data_type = 'decimal' THEN 'dec'
        WHEN c.data_type = 'float' THEN 'float4'
        WHEN c.data_type = 'double' THEN 'float8'
        WHEN c.data_type = 'bit' THEN 'bit'
        WHEN c.data_type = 'year' THEN 'int2'
        WHEN c.data_type = 'char' THEN 'char'
        WHEN c.data_type = 'varchar' THEN 'varchar'
        WHEN c.data_type IN ('tinytext', 'text', 'mediumtext', 'longtext') THEN 'text'
        WHEN c.data_type IN ('binary', 'varbinary', 'tinyblob', 'blob', 'mediumblob', 'longblob') THEN 'bytes'
        WHEN c.data_type = 'date' THEN 'date'
        WHEN c.data_type = 'time' THEN 'time'
        WHEN c.data_type = 'datetime' THEN 'ts'
        WHEN c.data_type = 'timestamp' THEN 'tstz'
        WHEN c.data_type = 'json' THEN 'json'
        WHEN c.data_type = 'uuid' THEN 'uuid'
        WHEN c.data_type IN ('enum', 'set') THEN 'enum'
        WHEN c.data_type IN ('geometry', 'point', 'linestring', 'polygon', 'multipoint', 'multilinestring', 'multipolygon', 'geometrycollection', 'geomcollection') THEN 'geom'
        ELSE 'other' END,
      COALESCE(c.character_maximum_length, 0), COALESCE(c.numeric_precision, 0), COALESCE(c.numeric_scale, 0),
      IF(c.is_nullable = 'YES', 'Y', 'N'), IF(c.extra LIKE '%auto_increment%', 'Y', 'N'),
      CONCAT(c.column_type, IF(c.extra LIKE '%VIRTUAL GENERATED%' OR c.extra LIKE '%STORED GENERATED%' OR c.extra IN ('VIRTUAL', 'PERSISTENT', 'STORED'), ' (generated)', ''), IF(c.extra LIKE '%on update%', ' (on update)', '')),
      CONCAT(IF(c.extra LIKE '%DEFAULT_GENERATED%', 'expr:', ''), COALESCE(c.column_default, ''))
    FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
    WHERE c.table_schema = DATABASE()
    ORDER BY c.table_name, c.ordinal_position" > "$X/columns.txt"

  q src "SELECT table_name, index_name, IF(MAX(non_unique) = 0, 'Y', 'N'), IF(index_name = 'PRIMARY', 'Y', 'N'),
      GROUP_CONCAT(COALESCE(column_name, '?') ORDER BY seq_in_index SEPARATOR ','),
      CASE WHEN MAX(index_type) IN ('FULLTEXT', 'SPATIAL') THEN CONCAT(LOWER(MAX(index_type)), ' index')
           WHEN SUM(column_name IS NULL) > 0 THEN 'expression index'
           WHEN SUM(sub_part IS NOT NULL) > 0 THEN 'prefix index (converted to a full-column index)' ELSE '' END
    FROM information_schema.statistics WHERE table_schema = DATABASE()
    GROUP BY table_name, index_name ORDER BY 1, 2" > "$X/.idx"
  awk -F'|' '$4 == "Y" { print $1 "|" $5 }' "$X/.idx" > "$X/pk.txt"
  # A prefix index is still created (on the whole column), so only the warning
  # is kept for it, not a skip.
  awk -F'|' -v w="$X/warnings.txt" 'BEGIN { OFS = "|" } $4 == "N" {
      r = $6; if (r ~ /^prefix/) { print "Index " $1 "." $2 ": " r >> w; r = "" }
      print $1, $2, $3, $5, r }' "$X/.idx" > "$X/indexes.txt"
  rm -f "$X/.idx"

  q src "SELECT k.table_name, k.constraint_name,
      GROUP_CONCAT(k.column_name ORDER BY k.ordinal_position SEPARATOR ','), k.referenced_table_name,
      GROUP_CONCAT(k.referenced_column_name ORDER BY k.ordinal_position SEPARATOR ','), r.delete_rule, r.update_rule
    FROM information_schema.key_column_usage k
    JOIN information_schema.referential_constraints r ON r.constraint_schema = k.constraint_schema AND r.constraint_name = k.constraint_name AND r.table_name = k.table_name
    WHERE k.table_schema = DATABASE() AND k.referenced_table_name IS NOT NULL
    GROUP BY k.table_name, k.constraint_name, k.referenced_table_name, r.delete_rule, r.update_rule ORDER BY 1, 2" > "$X/fks.txt"

  {
    use src; export DBM_SQL="SELECT CONCAT('-- VIEW ', table_name, '\n', 'CREATE VIEW ', table_name, ' AS ', view_definition, ';\n') FROM information_schema.views WHERE table_schema = DATABASE()
      UNION ALL SELECT CONCAT('-- ', routine_type, ' ', routine_name, '\n', '-- returns: ', COALESCE(dtd_identifier, '-'), '\n', routine_definition, '\n') FROM information_schema.routines WHERE routine_schema = DATABASE()
      UNION ALL SELECT CONCAT('-- TRIGGER ', trigger_name, ' ', action_timing, ' ', event_manipulation, ' ON ', event_object_table, ' FOR EACH ROW\n', action_statement, ';\n') FROM information_schema.triggers WHERE trigger_schema = DATABASE()
      UNION ALL SELECT CONCAT('-- EVENT ', event_name, '\n', event_definition, ';\n') FROM information_schema.events WHERE event_schema = DATABASE()"
    if [ "$SRC_ENGINE" = mariadb ]; then
      client mariadb 'mariadb $DBM_TLS -h "$DBM_H" -P "$DBM_P" -u "$DBM_U" -N -B --raw "$DBM_D" -e "$DBM_SQL"'
    else
      client mysql 'mysql $DBM_TLS -h "$DBM_H" -P "$DBM_P" -u "$DBM_U" -N -B --raw "$DBM_D" -e "$DBM_SQL"'
    fi
  } > "$X/manual_objects.sql"
  # ENUM value lists, to become CHECK constraints on PostgreSQL.
  : > "$X/enums.txt"
  grep -F '|enum|' "$X/columns.txt" | awk -F'|' '$10 ~ /^enum\(/ { print $2 "|" $3 "|" $10 }' > "$X/enums.txt" || true
}

x_extract_mongo() {
  js src '
    db.getCollectionInfos().forEach(c => {
      if (c.name.startsWith("system.")) return;
      if (c.type === "collection") print("C|" + c.name);
      else print("V|" + c.name);
    });' > "$X/.colls"
  awk -F'|' '$1 == "C" { print $2 }' "$X/.colls" > "$X/collections.txt"
  : > "$X/columns.txt"; : > "$X/pk.txt"; : > "$X/indexes.txt"; : > "$X/fks.txt"
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s|%s|_id|mongoid|255|0|0|N|N|_id|\n' "$c" "$c" >> "$X/columns.txt"
    printf '%s|%s|doc|json|0|0|0|N|N|document|\n' "$c" "$c" >> "$X/columns.txt"
  done < "$X/collections.txt"
  js src '
    db.getCollectionInfos().forEach(c => {
      if (c.name.startsWith("system.")) return;
      if (c.type === "view") print("// VIEW " + c.name + "\n" + EJSON.stringify(c.options) + "\n");
      if (c.options && c.options.validator) print("// VALIDATOR " + c.name + "\n" + EJSON.stringify(c.options.validator) + "\n");
      if (c.type === "collection") db.getCollection(c.name).getIndexes().forEach(i => {
        if (i.name !== "_id_") print("// INDEX " + c.name + "." + i.name + "\n" + EJSON.stringify(i) + "\n");
      });
    });' > "$X/manual_objects.js"
  rm -f "$X/.colls"
}

x_extract() {
  rm -f "$X"/*.txt "$X"/*.sql "$X"/*.js "$X/applied.env"
  : > "$X/warnings.txt"
  case "$SRC_ENGINE" in
    postgres) x_extract_pg ;;
    mariadb|mysql) x_extract_my ;;
    mongodb) x_extract_mongo ;;
  esac
  awk -F'|' '!seen[$2]++ { print $2 }' "$X/columns.txt" > "$X/tables.txt"
  # EXCLUDE_DATA_TABLES may name a table as "table" or "schema.table".
  local t r
  : > "$X/excluded.txt"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    r="$(awk -F'|' -v t="$t" '$2 == t { print $1; exit }' "$X/columns.txt")"
    r="${r//\"/}"; r="${r//\`/}"
    if is_excluded "$t" || is_excluded "$r"; then echo "$t" >> "$X/excluded.txt"; fi
  done < "$X/tables.txt"
  local dup
  dup="$(sort "$X/tables.txt" | uniq -d | head -5 | tr '\n' ' ')"
  [ -z "$dup" ] || die "the same table name exists in more than one source schema ($dup) — the target has one namespace. Migrate one schema at a time (SCHEMAS)."
}

# ── 2. type and default conversion ──────────────────────────────────────────

# x_type <gtype> <len> <prec> <scale> → target column type
x_type() {
  local g="$1" len="$2" prec="$3" scale="$4"
  case "$TGT_ENGINE" in
    postgres)
      case "$g" in
        int2) echo smallint ;; int4) echo integer ;; int8) echo bigint ;; uint8) echo "numeric(20,0)" ;;
        dec) if [ "$prec" -gt 0 ]; then echo "numeric($prec,$scale)"; else echo numeric; fi ;;
        float4) echo real ;; float8) echo "double precision" ;; bool) echo boolean ;; bit) echo bigint ;;
        char) echo "char($(( len > 0 ? len : 1 )))" ;; varchar) echo "varchar($len)" ;;
        text|enum|geom|other) echo text ;; bytes) echo bytea ;; date) echo date ;; time) echo time ;;
        ts) echo timestamp ;; tstz) echo timestamptz ;; json|array) echo jsonb ;; uuid) echo uuid ;;
        money) echo "numeric(19,2)" ;; interval) echo interval ;; mongoid) echo text ;;
        *) echo text ;;
      esac ;;
    mariadb|mysql)
      case "$g" in
        int2) echo SMALLINT ;; int4) echo INT ;; int8) echo BIGINT ;; uint8) echo "BIGINT UNSIGNED" ;;
        dec)
          if [ "$prec" -eq 0 ]; then echo "DECIMAL(65,30)"
          elif [ "$prec" -gt 65 ]; then echo "DECIMAL(65,$(( scale > 30 ? 30 : scale )))"
          else echo "DECIMAL($prec,$(( scale > 30 ? 30 : scale )))"; fi ;;
        float4) echo FLOAT ;; float8) echo DOUBLE ;; bool) echo "TINYINT(1)" ;; bit) echo BIGINT ;;
        char) if [ "$len" -gt 255 ]; then echo "VARCHAR($len)"; else echo "CHAR($(( len > 0 ? len : 1 )))"; fi ;;
        varchar) if [ "$len" -le 2000 ]; then echo "VARCHAR($len)"; else echo LONGTEXT; fi ;;
        text|geom|other) echo LONGTEXT ;; enum) echo "VARCHAR(255)" ;; bytes) echo LONGBLOB ;;
        date) echo DATE ;; time) echo "TIME(6)" ;; ts|tstz) echo "DATETIME(6)" ;;
        json|array) echo JSON ;; uuid) echo "CHAR(36)" ;; money) echo "DECIMAL(19,2)" ;; interval) echo "VARCHAR(64)" ;;
        mongoid) echo "VARCHAR(255)" ;;
        *) echo LONGTEXT ;;
      esac ;;
  esac
}

# Does this target type hold its data out of row (no literal DEFAULT in MySQL,
# needs a prefix to be indexed)?
x_my_lob() { case "$1" in LONGTEXT|LONGBLOB|JSON) return 0;; esac; return 1; }

# x_default <gtype> <raw default> <target type> → " DEFAULT …" or nothing
x_default() {
  local g="$1" raw="$2" tt="$3" kind="" val=""
  [ -n "$raw" ] || return 0
  case "$SRC_ENGINE" in
    postgres)
      if [[ "$raw" =~ ^\'(.*)\'::[a-z\ ]+(\([0-9,]+\))?(\[\])?$ ]]; then kind=L; val="'${BASH_REMATCH[1]}'"
      elif [[ "$raw" =~ ^\(?(-?[0-9]+(\.[0-9]+)?)\)?(::[a-z\ ]+)?$ ]]; then kind=N; val="${BASH_REMATCH[1]}"
      elif [[ "$raw" =~ ^(true|false)$ ]]; then kind=B; val="$raw"
      elif [[ "$raw" =~ ^(now\(\)|CURRENT_TIMESTAMP|transaction_timestamp\(\)|statement_timestamp\(\)|LOCALTIMESTAMP|clock_timestamp\(\))$ ]]; then kind=F; val=ts
      elif [ "$raw" = CURRENT_DATE ]; then kind=F; val=date
      elif [[ "$raw" =~ ^NULL ]]; then return 0
      fi ;;
    mariadb)
      if [ "$raw" = NULL ]; then return 0
      elif [[ "$raw" =~ ^\'.*\'$ ]]; then kind=L; val="$raw"
      elif [[ "$raw" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then kind=N; val="$raw"
      elif [[ "${raw,,}" =~ ^current_timestamp(\([0-9]*\))?$ ]]; then kind=F; val=ts
      elif [[ "${raw,,}" =~ ^(curdate\(\)|current_date(\(\))?)$ ]]; then kind=F; val=date
      fi ;;
    mysql)
      if [[ "$raw" == expr:* ]]; then
        raw="${raw#expr:}"
        if [[ "${raw,,}" =~ ^(current_timestamp(\([0-9]*\))?|now\(\))$ ]]; then kind=F; val=ts
        elif [[ "${raw,,}" =~ ^(curdate\(\)|current_date(\(\))?)$ ]]; then kind=F; val=date
        fi
      else
        case "$g" in
          int2|int4|int8|uint8|dec|float4|float8|bool|bit) [[ "$raw" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && { kind=N; val="$raw"; } ;;
          *) kind=L; val="'${raw//\'/\'\'}'" ;;
        esac
      fi ;;
  esac
  if [ -z "$kind" ]; then
    printf 'D\n' >&3   # signal: dropped
    return 0
  fi
  case "$TGT_ENGINE" in
    postgres)
      case "$kind" in
        N) if [ "$g" = bool ]; then [ "$val" = 0 ] && echo " DEFAULT false" || echo " DEFAULT true"; else echo " DEFAULT $val"; fi ;;
        B|L) echo " DEFAULT $val" ;;
        F) [ "$val" = ts ] && echo " DEFAULT CURRENT_TIMESTAMP" || echo " DEFAULT CURRENT_DATE" ;;
      esac ;;
    mariadb|mysql)
      if x_my_lob "$tt"; then printf 'D\n' >&3; return 0; fi
      case "$kind" in
        N) echo " DEFAULT $val" ;;
        B) [ "$val" = true ] && echo " DEFAULT 1" || echo " DEFAULT 0" ;;
        L) echo " DEFAULT $val" ;;
        F) if [ "$val" = ts ] && [[ "$tt" == DATETIME* ]]; then echo " DEFAULT CURRENT_TIMESTAMP(6)"
           elif [ "$val" = date ]; then echo " DEFAULT (CURRENT_DATE)"
           else printf 'D\n' >&3; fi ;;
      esac ;;
  esac
}

# Columns of one table: lines of columns.txt
x_cols() { awk -F'|' -v t="$1" '$2 == t' "$X/columns.txt"; }
x_coltype() { awk -F'|' -v t="$1" -v c="$2" '$2 == t && $3 == c { print $4 "|" $5; exit }' "$X/columns.txt"; }

# Index column for MySQL: LOBs need a prefix; JSON cannot be indexed.
x_my_idxcol() { # <table> <col> → `col`[(n)] or empty when not indexable
  local gl g len tt
  gl="$(x_coltype "$1" "$2")"; g="${gl%%|*}"; len="${gl##*|}"
  tt="$(x_type "$g" "$len" 0 0)"
  case "$tt" in
    JSON) return 1 ;;
    LONGTEXT|LONGBLOB) printf '%s(191)' "$(my_id "$2")"; return 2 ;;
    VARCHAR\(*) if [ "$len" -gt 768 ]; then printf '%s(768)' "$(my_id "$2")"; return 2; fi ;;
  esac
  my_id "$2"
}

x_trunc() { printf '%s' "${1:0:$2}"; }

# ── 3. render the target schema ─────────────────────────────────────────────
# schema.sql   CREATE TABLE … (applied before the data, must fully succeed)
# indexes.sql  one statement per line (after the data)
# fks.sql      one statement per line (after the data)
# post.sql     identity/sequence positions (PostgreSQL target)
x_render() {
  : > "$X/schema.sql"; : > "$X/indexes.sql"; : > "$X/fks.sql"; : > "$X/post.sql"; : > "$X/typemap.txt"
  [ "$TGT_ENGINE" != mongodb ] || { x_render_mongo; return; }
  local t
  if [ "$TGT_ENGINE" = postgres ]; then
    echo "CREATE SCHEMA IF NOT EXISTS $(pg_id "$TGT_SCHEMA");" >> "$X/schema.sql"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    x_render_table "$t"
  done < "$X/tables.txt"
  x_render_indexes
  x_render_fks
}

x_render_table() {
  local t="$1" ref defs="" srcref tn col g len prec scale nul auto stype def tt d auto_done="" ai_key=""
  ref="$(x_tgt_ref "$t")"
  local pkcols; pkcols="$(awk -F'|' -v t="$t" '$1 == t { print $2; exit }' "$X/pk.txt")"
  while IFS='|' read -r srcref tn col g len prec scale nul auto stype def; do
    tt="$(x_type "$g" "$len" "$prec" "$scale")"
    printf '%s|%s\n' "$stype" "$tt" >> "$X/typemap.txt"
    if [ "$SRC_ENGINE" = mongodb ]; then
      # _id derived from the document, so the load only writes `doc`.
      if [ "$col" = _id ]; then
        if [ "$TGT_ENGINE" = postgres ]; then
          defs+="${defs:+, }\"_id\" text GENERATED ALWAYS AS (coalesce(doc->'_id'->>'\$oid', doc->>'_id')) STORED"
        else
          defs+="${defs:+, }\`_id\` VARCHAR(255) AS (COALESCE(JSON_UNQUOTE(JSON_EXTRACT(\`doc\`, '\$._id.\"\$oid\"')), JSON_UNQUOTE(JSON_EXTRACT(\`doc\`, '\$._id')))) STORED"
        fi
      else
        if [ "$TGT_ENGINE" = postgres ]; then defs+="${defs:+, }\"doc\" jsonb NOT NULL"; else defs+="${defs:+, }\`doc\` JSON NOT NULL"; fi
      fi
      continue
    fi
    case "$g" in
      dec) [ "$prec" -gt 0 ] || [ "$TGT_ENGINE" = postgres ] || xwarn "$t.$col: unbounded numeric becomes DECIMAL(65,30) — values beyond that precision fail to load." ;;
      time) [[ "$stype" != *"with time zone"* ]] || xwarn "$t.$col: time with time zone loses its offset." ;;
      tstz) is_my "$TGT_ENGINE" && xwarn "$t.$col: timestamp with time zone becomes DATETIME(6) holding UTC." ;;
      enum) is_my "$TGT_ENGINE" && xwarn "$t.$col: enum type $stype becomes VARCHAR(255) (allowed values not enforced)." ;;
      geom) xwarn "$t.$col: $stype is migrated as WKT text." ;;
      array) xwarn "$t.$col: array $stype becomes a JSON array." ;;
      uint8) [ "$TGT_ENGINE" = postgres ] && xwarn "$t.$col: BIGINT UNSIGNED becomes numeric(20,0)." ;;
      other) xwarn "$t.$col: type $stype has no direct equivalent; migrated as text." ;;
      interval) is_my "$TGT_ENGINE" && xwarn "$t.$col: interval migrated as text." ;;
    esac
    [[ "$stype" != *"(generated)"* ]] || xwarn "$t.$col: generated column — its computed values are copied, the expression is not (re-create it by hand)."
    [[ "$stype" != *"(on update)"* ]] || xwarn "$t.$col: ON UPDATE CURRENT_TIMESTAMP has no column-level equivalent on PostgreSQL — needs a trigger."
    if [ "$g" = time ] && is_my "$SRC_ENGINE"; then xwarn "$t.$col: MySQL TIME may hold values beyond 24h or negative; PostgreSQL time cannot (such rows fail to load)."; fi
    local line
    if [ "$TGT_ENGINE" = postgres ]; then line="$(pg_id "$col") $tt"; else line="$(my_id "$col") $tt"; fi
    if [ "$auto" = Y ]; then
      case "$g" in
        int2|int4|int8|uint8)
          if [ "$TGT_ENGINE" = postgres ]; then
            line+=" GENERATED BY DEFAULT AS IDENTITY"
            echo "SELECT setval(pg_get_serial_sequence('$(sql_lit "$ref")', '$(sql_lit "$col")'), coalesce(max($(pg_id "$col")), 0) + 1, false) FROM $ref;" >> "$X/post.sql"
          elif [ -z "$auto_done" ]; then
            line+=" AUTO_INCREMENT"; auto_done="$col"
            [ "${pkcols%%,*}" = "$col" ] || ai_key=", KEY $(my_id "ai_$col") ($(my_id "$col"))"
          else
            xwarn "$t.$col: MySQL allows one AUTO_INCREMENT column per table; this one becomes a plain integer."
          fi ;;
        *) xwarn "$t.$col: auto-increment on a non-integer column is not converted." ;;
      esac
    fi
    [ "$nul" = Y ] || line+=" NOT NULL"
    d="$( { x_default "$g" "$def" "$tt" 3> "$X/.dflag"; } )"
    if [ -s "$X/.dflag" ]; then xwarn "$t.$col: default '$def' has no equivalent on $TGT_ENGINE and was dropped."; fi
    rm -f "$X/.dflag"
    line+="$d"
    if [ "$TGT_ENGINE" = postgres ] && [[ "$stype" =~ ^enum\((.*)\)$ ]]; then
      line+=" CHECK ($(pg_id "$col") IN (${BASH_REMATCH[1]}))"
    fi
    defs+="${defs:+, }$line"
  done < <(x_cols "$t")

  if [ -n "$pkcols" ] && [ "$SRC_ENGINE" != mongodb ]; then
    local pk="" c rc
    IFS=',' read -r -a _pkc <<<"$pkcols"
    for c in "${_pkc[@]}"; do
      if [ "$TGT_ENGINE" = postgres ]; then pk+="${pk:+, }$(pg_id "$c")"
      else
        set +e; local ic; ic="$(x_my_idxcol "$t" "$c")"; rc=$?; set -e
        [ "$rc" -ne 1 ] || die "$t: primary key column $c is JSON, which MySQL cannot index"
        [ "$rc" -ne 2 ] || xwarn "$t: primary key on long text column $c uses a 191-character prefix — uniqueness is checked on the prefix only."
        pk+="${pk:+, }$ic"
      fi
    done
    defs+=", PRIMARY KEY ($pk)"
  elif [ -z "$pkcols" ] && [ "$SRC_ENGINE" != mongodb ]; then
    xwarn "$t: no primary key on the source."
  fi
  defs+="$ai_key"

  if [ "$TGT_ENGINE" = postgres ]; then
    echo "CREATE TABLE $ref ($defs);" >> "$X/schema.sql"
  else
    echo "CREATE TABLE $ref ($defs) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=$MYSQL_TGT_COLLATION;" >> "$X/schema.sql"
  fi
  if [ "$SRC_ENGINE" = mongodb ]; then
    if [ "$TGT_ENGINE" = postgres ]; then
      echo "CREATE UNIQUE INDEX $(pg_id "$(x_trunc "${t}__id" 63)") ON $ref (\"_id\");" >> "$X/indexes.sql"
    else
      echo "CREATE UNIQUE INDEX \`_id\` ON $ref (\`_id\`);" >> "$X/indexes.sql"
    fi
  fi
}

x_render_indexes() {
  local t name uniq cols skip ref list c ic rc
  while IFS='|' read -r t name uniq cols skip; do
    [ -n "$t" ] || continue
    if [ -n "$skip" ]; then xwarn "Index $t.$name not converted: $skip (re-create it by hand)."; continue; fi
    ref="$(x_tgt_ref "$t")"; list=""
    IFS=',' read -r -a _ic <<<"$cols"
    local ok=1
    for c in "${_ic[@]}"; do
      if [ "$TGT_ENGINE" = postgres ]; then list+="${list:+, }$(pg_id "$c")"
      else
        set +e; ic="$(x_my_idxcol "$t" "$c")"; rc=$?; set -e
        if [ "$rc" -eq 1 ]; then xwarn "Index $t.$name not converted: column $c is JSON, which MySQL cannot index directly."; ok=0; break; fi
        [ "$rc" -ne 2 ] || [ "$uniq" != Y ] || xwarn "Unique index $t.$name: long text column $c is indexed on a 191-character prefix — uniqueness is checked on the prefix only."
        list+="${list:+, }$ic"
      fi
    done
    [ "$ok" = 1 ] || continue
    local u=""; [ "$uniq" = Y ] && u="UNIQUE "
    if [ "$TGT_ENGINE" = postgres ]; then
      # PostgreSQL index names are unique per schema, MySQL's only per table.
      echo "CREATE ${u}INDEX $(pg_id "$(x_trunc "${t}_${name}" 63)") ON $ref ($list);" >> "$X/indexes.sql"
    else
      echo "CREATE ${u}INDEX $(my_id "$(x_trunc "$name" 64)") ON $ref ($list);" >> "$X/indexes.sql"
    fi
  done < "$X/indexes.txt"
}

x_render_fks() {
  local t name cols rt rcols del upd idf cl rl c
  while IFS='|' read -r t name cols rt rcols del upd; do
    [ -n "$t" ] || continue
    if grep -qxF "$rt" "$X/tables.txt"; then :; else xwarn "Foreign key $t.$name references $rt, which is not migrated — skipped."; continue; fi
    if is_my "$TGT_ENGINE"; then
      [ "$del" != "SET DEFAULT" ] || { xwarn "Foreign key $t.$name: ON DELETE SET DEFAULT is not supported by InnoDB — becomes NO ACTION."; del="NO ACTION"; }
      [ "$upd" != "SET DEFAULT" ] || { xwarn "Foreign key $t.$name: ON UPDATE SET DEFAULT is not supported by InnoDB — becomes NO ACTION."; upd="NO ACTION"; }
    fi
    cl=""; rl=""
    IFS=',' read -r -a _fc <<<"$cols"; for c in "${_fc[@]}"; do if [ "$TGT_ENGINE" = postgres ]; then cl+="${cl:+, }$(pg_id "$c")"; else cl+="${cl:+, }$(my_id "$c")"; fi; done
    IFS=',' read -r -a _rc <<<"$rcols"; for c in "${_rc[@]}"; do if [ "$TGT_ENGINE" = postgres ]; then rl+="${rl:+, }$(pg_id "$c")"; else rl+="${rl:+, }$(my_id "$c")"; fi; done
    if [ "$TGT_ENGINE" = postgres ]; then idf="$(pg_id "$(x_trunc "$name" 63)")"; else idf="$(my_id "$(x_trunc "$name" 64)")"; fi
    echo "ALTER TABLE $(x_tgt_ref "$t") ADD CONSTRAINT $idf FOREIGN KEY ($cl) REFERENCES $(x_tgt_ref "$rt") ($rl) ON DELETE $del ON UPDATE $upd;" >> "$X/fks.sql"
  done < "$X/fks.txt"
}

# Relational → MongoDB: no DDL; indexes become createIndex calls.
x_render_mongo() {
  local t name uniq cols skip c spec filt g nul
  : > "$X/mongo_indexes.txt"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    local pk; pk="$(awk -F'|' -v t="$t" '$1 == t { print $2; exit }' "$X/pk.txt")"
    if [ -n "$pk" ] && [[ "$pk" == *,* ]]; then
      echo "$t|pk_$t|Y|$pk|" >> "$X/.mi"
    elif [ -z "$pk" ]; then
      xwarn "$t: no primary key — documents get a generated ObjectId _id."
    fi
  done < "$X/tables.txt"
  cat "$X/indexes.txt" >> "$X/.mi" 2>/dev/null || true
  while IFS='|' read -r t name uniq cols skip; do
    [ -n "$t" ] || continue
    [ -z "$skip" ] || { xwarn "Index $t.$name not converted: $skip."; continue; }
    spec=""; filt=""
    IFS=',' read -r -a _ic <<<"$cols"
    for c in "${_ic[@]}"; do
      spec+="${spec:+, }$(printf '%s' "$c" | sed 's/["\\]/\\&/g; s/.*/"&": 1/')"
      if [ "$uniq" = Y ]; then
        g="$(awk -F'|' -v t="$t" -v c="$c" '$2 == t && $3 == c { print $4; exit }' "$X/columns.txt")"
        nul="$(awk -F'|' -v t="$t" -v c="$c" '$2 == t && $3 == c { print $8; exit }' "$X/columns.txt")"
        if [ "$nul" = Y ]; then
          # SQL lets a unique column hold many NULLs; MongoDB would not. Limit
          # the uniqueness to documents where the value is present.
          local ty
          case "$g" in
            int2|int4|int8|uint8|dec|float4|float8|money|bit) ty=number ;; bool) ty=bool ;;
            date|ts|tstz) ty=date ;; bytes) ty=binData ;; json|array) ty=object ;; *) ty=string ;;
          esac
          filt+="${filt:+, }$(printf '%s' "$c" | sed 's/["\\]/\\&/g; s/.*/"&"/'): { \$type: \"$ty\" }"
        fi
      fi
    done
    local opts="name: $(printf '%s' "$name" | sed 's/["\\]/\\&/g; s/.*/"&"/')"
    [ "$uniq" != Y ] || opts+=", unique: true"
    [ -z "$filt" ] || opts+=", partialFilterExpression: { $filt }"
    printf '%s\t{ %s }\t{ %s }\n' "$t" "$spec" "$opts" >> "$X/mongo_indexes.txt"
  done < "$X/.mi"
  rm -f "$X/.mi"
  [ ! -s "$X/fks.txt" ] || xwarn "$(grep -c . "$X/fks.txt") foreign key(s): MongoDB has no foreign keys — integrity must be enforced by the application."
  local stype tt
  while IFS='|' read -r _ _ _ g _ _ _ _ _ stype _; do
    case "$g" in
      int8) tt=long ;; uint8|dec|money) tt=decimal ;; date|ts|tstz) tt=date ;; bytes) tt=binData ;;
      json) tt="embedded document" ;; array) tt=array ;; int2|int4) tt=int ;; float4|float8) tt=double ;;
      bool) tt="bool (from $g)" ;; *) tt=string ;;
    esac
    printf '%s|%s\n' "$stype" "$tt" >> "$X/typemap.txt"
  done < "$X/columns.txt"
}

# ── 4. the conversion report ────────────────────────────────────────────────

x_manual_count() {
  local f
  for f in "$X/manual_objects.sql" "$X/manual_objects.js"; do
    [ -f "$f" ] && grep -cE '^(--|//) (VIEW|MATERIALIZED|FUNCTION|PROCEDURE|TRIGGER|CHECK|EVENT|VALIDATOR|INDEX)' "$f" && return
  done
  echo 0
}

x_write_report() {
  local f="$STATE/conversion.md" n
  {
    echo "# Schema conversion — $SRC_ENGINE → $TGT_ENGINE"
    echo
    echo "Generated $(date -u +%FT%TZ). The exact target DDL is in \`xengine/schema.sql\`, \`xengine/indexes.sql\` and \`xengine/fks.sql\` — review it like any other migration."
    echo
    echo "| | Count |"
    echo "|---|---|"
    echo "| Tables / collections | $(grep -c . "$X/tables.txt" || true) |"
    echo "| Columns | $(grep -c . "$X/columns.txt" || true) |"
    if [ "$TGT_ENGINE" = mongodb ]; then
      echo "| Indexes to create | $(grep -c . "$X/mongo_indexes.txt" || true) |"
    else
      echo "| Indexes to create | $(grep -c . "$X/indexes.sql" || true) |"
      echo "| Foreign keys to create | $(grep -c . "$X/fks.sql" || true) |"
    fi
    n="$(x_manual_count)"
    echo "| **Objects needing manual conversion** | **$n** |"
    echo
    echo "## Type mapping"
    echo
    echo "| Source type | Target type | Columns |"
    echo "|---|---|---|"
    sort "$X/typemap.txt" | uniq -c | sort -rn | awk '{ n = $1; $1 = ""; sub(/^ /, ""); split($0, p, "|"); printf "| %s | %s | %d |\n", p[1], p[2], n }'
    echo
    if [ "$SRC_ENGINE" = mongodb ]; then
      echo "Each collection becomes a table with the whole document in a JSON column (\`doc\`) and \`_id\` derived from it — nothing is lost. Promote fields you query often to real columns after the migration, e.g. PostgreSQL: \`ALTER TABLE t ADD COLUMN email text GENERATED ALWAYS AS (doc->>'email') STORED\`."
      echo
    fi
    if [ "$TGT_ENGINE" = mongodb ]; then
      echo "Each row becomes one document. A single-column primary key becomes \`_id\` (the column is kept too); dates become BSON dates (UTC), BIGINT becomes long, DECIMAL becomes Decimal128, binary becomes BinData."
      echo
    fi
    echo "## Behaviour differences to test"
    echo
    case "$SRC_ENGINE/$TGT_ENGINE" in
      postgres/mariadb|postgres/mysql)
        echo "- Text is case-sensitive on PostgreSQL. The target database uses \`$MYSQL_TGT_COLLATION\` (set MYSQL_TGT_COLLATION) — with a case-insensitive collation, unique keys on values that differ only by case fail to load."
        echo "- MySQL treats trailing spaces and empty strings differently in comparisons; check queries that compare CHAR values."
        echo "- Booleans become TINYINT(1); \`timestamptz\` becomes DATETIME(6) in UTC." ;;
      mariadb/postgres|mysql/postgres)
        echo "- MySQL compares text case-insensitively by default; PostgreSQL does not. Queries like \`WHERE email = 'A@x.com'\` may stop matching — use \`citext\` or \`lower()\` where the application relies on it."
        echo "- Zero dates (\`0000-00-00\`) cannot exist in PostgreSQL and are loaded as NULL (a NOT NULL column with zero dates fails to load)."
        echo "- \`TINYINT(1)\` becomes boolean (TINYINT1_AS_BOOL=$TINYINT1_AS_BOOL); a value other than 0/1 fails to load — set TINYINT1_AS_BOOL=false to keep it numeric."
        echo "- MySQL \`TIMESTAMP\` values are read in UTC and loaded as \`timestamptz\`; \`DATETIME\` becomes \`timestamp\` (no zone)." ;;
      mongodb/*)
        echo "- Applications move from the MongoDB query language to SQL over a JSON column — this is an application change, not only a data move." ;;
      */mongodb)
        echo "- Joins, transactions across tables and foreign keys are the application's job in MongoDB."
        echo "- NULL columns are kept as \`null\` fields." ;;
    esac
    echo
    echo "## Warnings"
    echo
    if [ -s "$X/warnings.txt" ]; then sort -u "$X/warnings.txt" | sed 's/^/- /'; else echo "- none"; fi
    echo
    echo "## Needs manual conversion"
    echo
    if [ "$n" -gt 0 ]; then
      echo "These are code in the source engine's dialect. They were exported (not converted) to \`xengine/manual_objects.$( [ "$SRC_ENGINE" = mongodb ] && echo js || echo sql )\`. Rewrite them for $TGT_ENGINE and apply them after the load:"
      echo
      grep -hE '^(--|//) (VIEW|MATERIALIZED|FUNCTION|PROCEDURE|TRIGGER|CHECK|EVENT|VALIDATOR|INDEX)' "$X"/manual_objects.* 2>/dev/null | sed -E 's#^(--|//) #- #'
    else
      echo "- none"
    fi
  } > "$f"
}

# Run during assess: extract, convert, report — without touching the target.
x_preview() {
  x_init
  log "cross-engine: converting the schema ($SRC_ENGINE → $TGT_ENGINE) for review"
  x_extract
  x_render
  x_write_report
  local w n
  w="$(sort -u "$X/warnings.txt" | grep -c . || true)"; n="$(x_manual_count)"
  ok "conversion report: $STATE/conversion.md ($w warning(s), $n object(s) need manual conversion)"
  [ "$n" -eq 0 ] || WARNINGS+=("$n view(s)/function(s)/trigger(s)/other objects cannot be converted automatically — exported to xengine/manual_objects.* for manual conversion (see conversion.md).")
  [ "$w" -eq 0 ] || NOTES+=("$w schema conversion warning(s) — review conversion.md.")
  A[XENGINE]=yes
  A[MANUAL_OBJECTS]="$n"
}

# Target checks for a cross-engine pair (the target is a different engine).
x_assess_target() {
  x_init
  log "target ($TGT_ENGINE): connectivity, version, emptiness"
  local row
  case "$TGT_ENGINE" in
    postgres)
      if row="$(q tgt "SELECT current_setting('server_version'), pg_encoding_to_char(d.encoding), d.datcollate FROM pg_database d WHERE d.datname = current_database()")"; then
        IFS='|' read -r A[TGT_VERSION] A[TGT_ENCODING] A[TGT_COLLATION] <<<"$row"
        ok "PostgreSQL ${A[TGT_VERSION]}, ${A[TGT_ENCODING]}"
        [ "${A[TGT_ENCODING]}" = UTF8 ] || BLOCKERS+=("Target database encoding is ${A[TGT_ENCODING]}; cross-engine loads need UTF8.")
        A[TGT_OBJECTS]="$(q tgt "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','v','m','S','f') AND n.nspname = '$TGT_SCHEMA'")"
      else
        BLOCKERS+=("Cannot connect to the TARGET ($TGT_HOST:$TGT_PORT/$TGT_DB). Check network, credentials and TGT_SSL.")
      fi ;;
    mariadb|mysql)
      if row="$(QDB='' q tgt "SELECT VERSION(), @@character_set_server")"; then
        IFS='|' read -r A[TGT_VERSION] A[TGT_ENCODING] <<<"$row"
        ok "${A[TGT_VERSION]}"
        A[TGT_OBJECTS]="$(QDB='' q tgt "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$TGT_DB'")"
        local coll
        coll="$(QDB='' q tgt "SELECT count(*) FROM information_schema.collations WHERE collation_name = '$MYSQL_TGT_COLLATION'")"
        [ "$coll" != 0 ] || BLOCKERS+=("Collation $MYSQL_TGT_COLLATION does not exist on the target (MYSQL_TGT_COLLATION).")
      else
        BLOCKERS+=("Cannot connect to the TARGET ($TGT_HOST:$TGT_PORT). Check network, credentials and TGT_SSL.")
      fi ;;
    mongodb)
      if row="$(js tgt 'print(db.version() + "|" + db.getCollectionNames().filter(n => !n.startsWith("system.")).length)')"; then
        IFS='|' read -r A[TGT_VERSION] A[TGT_OBJECTS] <<<"$row"
        A[TGT_ENCODING]="UTF-8 (BSON)"
        ok "MongoDB ${A[TGT_VERSION]}"
      else
        BLOCKERS+=("Cannot connect to the TARGET ($TGT_HOST:$TGT_PORT). Check network, credentials, TGT_AUTH_DB and TGT_SSL.")
      fi ;;
  esac
  CDC_ISSUES+=("Cross-engine ($SRC_ENGINE → $TGT_ENGINE): this tool moves data with a full load only — there is no cross-engine CDC, so the load must fit in the downtime window.")
}

# ── 5. moving the data ──────────────────────────────────────────────────────

# Streams one source table into the target. Runs in a subshell (parallel).
x_copy_table() {
  local t="$1" srcref cols="" exprs="" col g line sql pk
  srcref="$(awk -F'|' -v t="$t" '$2 == t { print $1; exit }' "$X/columns.txt")"
  pk="$(awk -F'|' -v t="$t" '$1 == t { print $2; exit }' "$X/pk.txt" 2>/dev/null)"
  local excluded=0
  grep -qxF "$t" "$X/excluded.txt" && excluded=1
  [ "$excluded" = 0 ] || { echo "skipped (EXCLUDE_DATA_TABLES)"; return 0; }

  case "$SRC_ENGINE/$TGT_ENGINE" in
    postgres/mariadb|postgres/mysql)
      while IFS='|' read -r _ _ col g _; do
        local c v; c="$(pg_id "$col")"
        case "$g" in
          int2|int4|int8|uint8|dec|float4|float8) v="$c::text" ;;
          money) v="$c::numeric::text" ;;
          bool) v="CASE WHEN $c THEN '1' ELSE '0' END" ;;
          bytes) v="'X''' || encode($c, 'hex') || ''''" ;;
          date) v="'''' || to_char($c, 'YYYY-MM-DD') || ''''" ;;
          time) v="'''' || ($c::time)::text || ''''" ;;
          ts) v="'''' || to_char($c, 'YYYY-MM-DD HH24:MI:SS.US') || ''''" ;;
          tstz) v="'''' || to_char($c AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || ''''" ;;
          array) v="$(tpl "$TPL_PG_MYLIT" "array_to_json($c)::text")" ;;
          *) v="$(tpl "$TPL_PG_MYLIT" "$c::text")" ;;
        esac
        exprs+="${exprs:+ || ',' || }CASE WHEN $c IS NULL THEN 'NULL' ELSE $v END"
        cols+="${cols:+,}$(my_id "$col")"
      done < <(x_cols "$t")
      sql="SELECT '(' || $exprs || ')' FROM $srcref"
      local hdr="INSERT INTO $(my_id "$t") ($cols) VALUES "
      ( use src; export DBM_SQL="$sql"
        client postgres 'psql -X -A -t -q -v ON_ERROR_STOP=1 -v FETCH_COUNT=5000 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -c "$DBM_SQL"' ) \
        | x_batch_inserts "$hdr" \
        | ( use tgt; client "$TGT_ENGINE" "$(x_my_load_cmd)" ) ;;

    mariadb/postgres|mysql/postgres)
      while IFS='|' read -r _ _ col g _; do
        local c v; c="$(my_id "$col")"
        case "$g" in
          int2|int4|int8|uint8|dec|float4|float8|bool|time) v="CAST($c AS CHAR)" ;;
          bit) v="CAST($c + 0 AS CHAR)" ;;
          bytes) v="$(tpl "$TPL_MY_HEX" "$c")" ;;
          date) v="IF(CAST($c AS CHAR) LIKE '0000-00-00%', NULL, DATE_FORMAT($c, '%Y-%m-%d'))" ;;
          ts) v="IF(CAST($c AS CHAR) LIKE '0000-00-00%', NULL, DATE_FORMAT($c, '%Y-%m-%d %H:%i:%s.%f'))" ;;
          tstz) v="IF(CAST($c AS CHAR) LIKE '0000-00-00%', NULL, CONCAT(DATE_FORMAT($c, '%Y-%m-%d %H:%i:%s.%f'), '+00'))" ;;
          geom) v="$(tpl "$TPL_MY_COPYESC" "ST_AsText($c)")" ;;
          *) v="$(tpl "$TPL_MY_COPYESC" "CAST($c AS CHAR)")" ;;
        esac
        exprs+="${exprs:+, }$(tpl "$TPL_MY_NULL" "$v")"
        cols+="${cols:+, }$(pg_id "$col")"
      done < <(x_cols "$t")
      sql="SET SESSION sql_mode = ''; SET SESSION time_zone = '+00:00'; SELECT CONCAT_WS('\t', $exprs) FROM $srcref"
      ( use src; export DBM_SQL="$sql"; client "$SRC_ENGINE" "$(x_my_dump_cmd)" ) \
        | ( use tgt; export DBM_SQL="COPY $(x_tgt_ref "$t") ($cols) FROM STDIN"
            client postgres 'psql -X -q -v ON_ERROR_STOP=1 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -c "$DBM_SQL"' ) ;;

    postgres/mongodb)
      while IFS='|' read -r _ _ col g _; do
        local c v; c="$(pg_id "$col")"
        case "$g" in
          ts) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$date', to_char($c, 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')) END" ;;
          tstz) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$date', to_char($c AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')) END" ;;
          date) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$date', to_char($c, 'YYYY-MM-DD\"T00:00:00.000Z\"')) END" ;;
          int8) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$numberLong', $c::text) END" ;;
          dec|money) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$numberDecimal', $c::numeric::text) END" ;;
          bytes) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$binary', json_build_object('base64', replace(encode($c, 'base64'), chr(10), ''), 'subType', '00')) END" ;;
          json) v="$c::json" ;;
          array) v="array_to_json($c)" ;;
          # Typed explicitly: a plain JSON 1.0 would arrive as an int.
          float4|float8) v="CASE WHEN $c IS NULL THEN NULL ELSE json_build_object('\$numberDouble', $c::text) END" ;;
          bool|int2|int4) v="$c" ;;
          *) v="$c::text" ;;
        esac
        exprs+="${exprs:+, }$v AS $(pg_id "$col")"
        [[ -z "$pk" || "$pk" == *,* || "$pk" != "$col" ]] || exprs+=", $v AS \"_id\""
      done < <(x_cols "$t")
      sql="SELECT row_to_json(x)::text FROM (SELECT $exprs FROM $srcref) x"
      ( use src; export DBM_SQL="$sql"
        client postgres 'psql -X -A -t -q -v ON_ERROR_STOP=1 -v FETCH_COUNT=5000 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -c "$DBM_SQL"' ) \
        | x_mongoimport "$t" ;;

    mariadb/mongodb|mysql/mongodb)
      while IFS='|' read -r _ _ col g _; do
        local c v n; c="$(my_id "$col")"; n="'$(my_lit "$col")'"
        case "$g" in
          ts|tstz) v="IF($c IS NULL OR CAST($c AS CHAR) LIKE '0000-00-00%', NULL, JSON_OBJECT('\$date', CONCAT(DATE_FORMAT($c, '%Y-%m-%dT%H:%i:%s.'), LPAD(FLOOR(MICROSECOND($c) / 1000), 3, '0'), 'Z')))" ;;
          date) v="IF($c IS NULL OR CAST($c AS CHAR) LIKE '0000-00-00%', NULL, JSON_OBJECT('\$date', DATE_FORMAT($c, '%Y-%m-%dT00:00:00.000Z')))" ;;
          int8) v="IF($c IS NULL, NULL, JSON_OBJECT('\$numberLong', CAST($c AS CHAR)))" ;;
          # BIGINT UNSIGNED can exceed a 64-bit long; Decimal128 holds all 20 digits.
          uint8|dec) v="IF($c IS NULL, NULL, JSON_OBJECT('\$numberDecimal', CAST($c AS CHAR)))" ;;
          bytes) v="IF($c IS NULL, NULL, JSON_OBJECT('\$binary', JSON_OBJECT('base64', $(tpl "$TPL_MY_B64" "$c"), 'subType', '00')))" ;;
          json) if [ "$SRC_ENGINE" = mysql ]; then v="CAST($c AS JSON)"; else v="JSON_EXTRACT($c, '\$')"; fi ;;
          bit) v="$c + 0" ;;
          geom) v="ST_AsText($c)" ;;
          time) v="CAST($c AS CHAR)" ;;
          bool) v="IF($c IS NULL, NULL, IF($c <> 0, JSON_EXTRACT('true', '\$'), JSON_EXTRACT('false', '\$')))" ;;
          float4|float8) v="IF($c IS NULL, NULL, JSON_OBJECT('\$numberDouble', CAST($c AS CHAR)))" ;;
          *) v="$c" ;;
        esac
        exprs+="${exprs:+, }$n, $v"
        [[ -z "$pk" || "$pk" == *,* || "$pk" != "$col" ]] || exprs+=", '_id', $v"
      done < <(x_cols "$t")
      sql="SET SESSION sql_mode = ''; SET SESSION time_zone = '+00:00'; SELECT JSON_OBJECT($exprs) FROM $srcref"
      ( use src; export DBM_SQL="$sql"; client "$SRC_ENGINE" "$(x_my_dump_cmd)" ) | x_mongoimport "$t" ;;

    mongodb/postgres)
      ( use src; client mongodb "$MCFG mongoexport --config=\"\$c\" --db=\"\$DBM_D\" --collection='$(printf '%s' "$t" | sed "s/'/'\\\\''/g")' --jsonFormat=relaxed --quiet" ) \
        | sed 's/\\/\\\\/g' \
        | ( use tgt; export DBM_SQL="COPY $(x_tgt_ref "$t") (\"doc\") FROM STDIN"
            client postgres 'psql -X -q -v ON_ERROR_STOP=1 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -c "$DBM_SQL"' ) ;;

    mongodb/mariadb|mongodb/mysql)
      ( use src; client mongodb "$MCFG mongoexport --config=\"\$c\" --db=\"\$DBM_D\" --collection='$(printf '%s' "$t" | sed "s/'/'\\\\''/g")' --jsonFormat=relaxed --quiet" ) \
        | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e "s/.*/('&')/" \
        | x_batch_inserts "INSERT INTO $(my_id "$t") (\`doc\`) VALUES " \
        | ( use tgt; client "$TGT_ENGINE" "$(x_my_load_cmd)" ) ;;
  esac
}

x_my_dump_cmd() {
  local bin=mariadb; [ "$SRC_ENGINE" = mysql ] && bin=mysql
  printf '%s $DBM_TLS -h "$DBM_H" -P "$DBM_P" -u "$DBM_U" -N -B --raw --quick --default-character-set=utf8mb4 "$DBM_D" -e "$DBM_SQL"' "$bin"
}
x_my_load_cmd() { # [extra client options]
  local bin=mariadb; [ "$TGT_ENGINE" = mysql ] && bin=mysql
  printf '%s $DBM_TLS -h "$DBM_H" -P "$DBM_P" -u "$DBM_U" --default-character-set=utf8mb4 --max-allowed-packet=1G %s "$DBM_D"' "$bin" "${1:-}"
}

# Lines "(v, v, …)" → multi-row INSERTs of ≤1000 rows / ~4 MB, so neither a
# huge table nor a large row exceeds the server's max_allowed_packet.
x_batch_inserts() {
  LC_ALL=C awk -v hdr="$1" '
    BEGIN { print "SET SESSION sql_mode = '\''STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO'\'';"
            print "SET SESSION foreign_key_checks = 0; SET SESSION unique_checks = 0; SET SESSION time_zone = '\''+00:00'\'';" }
    { if (n == 0) printf "%s%s", hdr, $0; else printf ",%s", $0
      n++; sz += length($0)
      if (n >= 1000 || sz > 4000000) { print ";"; n = 0; sz = 0 } }
    END { if (n) print ";" }'
}

x_mongoimport() {
  ( use tgt; client mongodb "$MCFG mongoimport --config=\"\$c\" --db=\"\$DBM_D\" --collection='$(printf '%s' "$1" | sed "s/'/'\\\\''/g")' --type=json --mode=insert --stopOnError --numInsertionWorkers=$JOBS" )
}

# apply <file> — statements one per line, continue past errors; prints the
# number of failed statements and keeps the messages in apply_errors.txt.
x_apply() {
  local f="$1" err="$X/.apply.err" n=0
  [ -s "$f" ] || { echo 0; return 0; }
  case "$TGT_ENGINE" in
    postgres)
      ( use tgt; client postgres 'psql -X -q -v ON_ERROR_STOP=0 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -f -' ) < "$f" > /dev/null 2> "$err" || true
      n="$(grep -c 'ERROR:' "$err" || true)" ;;
    mariadb|mysql)
      ( use tgt; client "$TGT_ENGINE" "$(x_my_load_cmd --force)" ) < "$f" > /dev/null 2> "$err" || true
      n="$(grep -c '^ERROR' "$err" || true)" ;;
  esac
  cat "$err" >> "$X/apply_errors.txt"; rm -f "$err"
  echo "$n"
}

x_full_load() {
  x_init
  [ "$STRATEGY" = full-load ] || die "cross-engine migrations are full load only (no CDC between different engines) — re-plan with --strategy full-load"
  log "cross-engine: converting the schema"
  x_extract
  x_render
  x_write_report
  : > "$X/apply_errors.txt"

  log "creating the target schema"
  case "$TGT_ENGINE" in
    postgres)
      ( use tgt; client postgres 'psql -X -q -v ON_ERROR_STOP=1 -h "$DBM_H" -p "$DBM_P" -U "$DBM_U" -d "$DBM_D" -f -' ) < "$X/schema.sql" 2> "$X/schema.err" \
        || { cat "$X/schema.err" >&2; die "creating the tables failed — see above and $X/schema.sql"; } ;;
    mariadb|mysql)
      QDB='' q tgt "CREATE DATABASE IF NOT EXISTS $(my_id "$TGT_DB") CHARACTER SET utf8mb4 COLLATE $MYSQL_TGT_COLLATION" >/dev/null
      ( use tgt; client "$TGT_ENGINE" "$(x_my_load_cmd)" ) < "$X/schema.sql" 2> "$X/schema.err" \
        || { cat "$X/schema.err" >&2; die "creating the tables failed — see above and $X/schema.sql"; } ;;
    mongodb) : ;;
  esac
  ok "$(grep -c . "$X/tables.txt") table(s) created"

  log "copying data ($JOBS in parallel)"
  local t running=0 failed=0
  mkdir -p "$X/copy"; rm -f "$X"/copy/*
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    (
      t0="$(date +%s)"
      if x_copy_table "$t" > "$X/copy/$t.log" 2>&1; then
        echo "ok $(( $(date +%s) - t0 ))" > "$X/copy/$t.status"
      else
        echo "fail" > "$X/copy/$t.status"
      fi
    ) < /dev/null &
    running=$(( running + 1 ))
    if [ "$running" -ge "$JOBS" ]; then wait -n || true; running=$(( running - 1 )); fi
  done < "$X/tables.txt"
  wait || true
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$(cut -d' ' -f1 "$X/copy/$t.status" 2>/dev/null)" = ok ]; then
      info "✓ $t ($(cut -d' ' -f2 "$X/copy/$t.status")s)"
    else
      failed=$(( failed + 1 ))
      warn "✗ $t — $(grep -v '^\s*$' "$X/copy/$t.log" | tail -3 | tr '\n' ' ')"
    fi
  done < "$X/tables.txt"
  [ "$failed" -eq 0 ] || die "$failed table(s) failed to copy — logs in $X/copy/. The target is partly loaded: empty it before retrying."

  local ip=0 if=0 fp=0 ff=0
  if [ "$TGT_ENGINE" = mongodb ]; then
    log "creating indexes"
    ip="$(grep -c . "$X/mongo_indexes.txt" || true)"
    if [ "$ip" -gt 0 ]; then
      local jsx="let f = 0;"$'\n' coll spec opts
      while IFS=$'\t' read -r coll spec opts; do
        jsx+="try { db.getCollection($(printf '%s' "$coll" | sed 's/["\\]/\\&/g; s/.*/"&"/')).createIndex($spec, $opts); } catch (e) { f++; print(\"ERROR \" + e.message); }"$'\n'
      done < "$X/mongo_indexes.txt"
      jsx+='print("FAILED=" + f);'
      js tgt "$jsx" > "$X/.mi.out"
      if="$(sed -n 's/^FAILED=//p' "$X/.mi.out")"; grep '^ERROR' "$X/.mi.out" >> "$X/apply_errors.txt" || true
      rm -f "$X/.mi.out"
    fi
  else
    if [ -s "$X/post.sql" ]; then
      log "setting identity/sequence positions"
      [ "$(x_apply "$X/post.sql")" = 0 ] || die "setting sequence positions failed — see $X/apply_errors.txt"
    fi
    log "creating indexes"
    ip="$(grep -c . "$X/indexes.sql" || true)"; if="$(x_apply "$X/indexes.sql")"
    log "creating foreign keys"
    fp="$(grep -c . "$X/fks.sql" || true)"; ff="$(x_apply "$X/fks.sql")"
  fi
  printf 'IDX_PLANNED=%s\nIDX_FAILED=%s\nFK_PLANNED=%s\nFK_FAILED=%s\n' "$ip" "${if:-0}" "$fp" "${ff:-0}" > "$X/applied.env"
  ok "indexes: $(( ip - ${if:-0} ))/$ip   foreign keys: $(( fp - ${ff:-0} ))/$fp"
  [ "${if:-0}" = 0 ] && [ "${ff:-0}" = 0 ] || warn "some indexes/foreign keys failed (they usually point at data that breaks a constraint on the target) — $X/apply_errors.txt"
  local n; n="$(x_manual_count)"
  [ "$n" -eq 0 ] || warn "$n object(s) need manual conversion: $X/manual_objects.* (listed in conversion.md)"
}

# ── 6. validation ───────────────────────────────────────────────────────────

# x_fp_sql <side> <engine> → one query: table|count[/sum/sum…] for every table
x_fp_sql() {
  local side="$1" engine="$2" t sql="" ref parts col g cexpr
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$side" = src ]; then ref="$(awk -F'|' -v t="$t" '$2 == t { print $1; exit }' "$X/columns.txt")"; else ref="$(x_tgt_ref "$t")"; fi
    parts=""
    if [ "${OPT_CHECKSUM:-0}" = 1 ]; then
      while IFS='|' read -r _ _ col g _; do
        case "$engine" in
          postgres) cexpr="$(pg_id "$col")" ;;
          *) cexpr="$(my_id "$col")" ;;
        esac
        case "$g" in
          int2|int4|int8|uint8)
            parts+=", coalesce(sum($cexpr), 0)" ;;
          bool)
            if [ "$engine" = postgres ]; then parts+=", coalesce(sum($cexpr::int), 0)"; else parts+=", coalesce(sum($cexpr), 0)"; fi ;;
          text|varchar|char)
            if [ "$engine" = postgres ]; then parts+=", coalesce(sum(char_length($cexpr::text)), 0)"
            else parts+=", coalesce(sum(char_length($cexpr)), 0)"; fi ;;
        esac
      done < <(x_cols "$t")
    fi
    if [ "$engine" = postgres ]; then
      sql+="${sql:+ UNION ALL }SELECT '$(sql_lit "$t")', concat_ws('/', count(*)$parts) FROM $ref"
    else
      sql+="${sql:+ UNION ALL }SELECT '$(my_lit "$t")', CONCAT_WS('/', COUNT(*)$parts) FROM $ref"
    fi
  done
  printf '%s' "$sql"
}

x_counts() { # x_counts <side> <engine> < tables  → "table|value" lines
  local side="$1" engine="$2"
  if [ "$engine" = mongodb ]; then
    local jsx="" t
    while IFS= read -r t; do
      [ -n "$t" ] && jsx+="print($(printf '%s' "$t" | sed 's/["\\]/\\&/g; s/.*/"&"/') + \"|\" + db.getCollection($(printf '%s' "$t" | sed 's/["\\]/\\&/g; s/.*/"&"/')).countDocuments({}));"$'\n'
    done
    [ -z "$jsx" ] || js "$side" "$jsx"
    return
  fi
  local sql; sql="$(x_fp_sql "$side" "$engine")"
  [ -z "$sql" ] || q "$side" "$sql"
}

x_validate() {
  x_init
  [ -s "$X/tables.txt" ] || die "nothing to validate — run full-load first"
  local out="$STATE/validation.md" fail=0 t s d chk="${OPT_CHECKSUM:-0}"
  ( [ "$SRC_ENGINE" = mongodb ] || [ "$TGT_ENGINE" = mongodb ] ) && chk=0
  log "validating ($SRC_ENGINE → $TGT_ENGINE): row counts$( [ "$chk" = 1 ] && echo ', integer sums and text lengths per table' )"
  grep -vxF -f "$X/excluded.txt" "$X/tables.txt" > "$X/.vt" || true
  OPT_CHECKSUM="$chk" x_counts src "$SRC_ENGINE" < "$X/.vt" | sort > "$X/.vs"
  OPT_CHECKSUM="$chk" x_counts tgt "$TGT_ENGINE" < "$X/.vt" | sort > "$X/.vd"
  {
    echo "# Validation — $MIGRATION_NAME ($SRC_ENGINE → $TGT_ENGINE)"
    echo
    echo "Run $(date -u +%FT%TZ). $( [ "$chk" = 1 ] && echo 'Each value is rows / sum of every integer and boolean column / total characters of every text column — computed independently by each engine.' || echo 'Row counts (add --checksum for per-column sums and text lengths on SQL ⇄ SQL).' )"
    echo
    echo "## Tables"
    echo
    echo "| Table | Source | Target | |"
    echo "|---|---|---|---|"
  } > "$out"
  while IFS='|' read -r t s; do
    [ -n "$t" ] || continue
    d="$(awk -F'|' -v k="$t" '$1 == k { print $2; exit }' "$X/.vd")"
    if [ "$s" = "$d" ]; then echo "| \`$t\` | $s | $d | ✅ |" >> "$out"
    else echo "| \`$t\` | $s | ${d:-missing} | ❌ |" >> "$out"; fail=$(( fail + 1 )); fi
  done < "$X/.vs"
  while IFS= read -r t; do [ -n "$t" ] && echo "| \`$t\` | — | — | data excluded |" >> "$out"; done < "$X/excluded.txt"
  {
    echo
    echo "## Schema objects"
    echo
    echo "| Kind | Planned | Created | |"
    echo "|---|---|---|---|"
  } >> "$out"
  if [ -f "$X/applied.env" ]; then
    local IDX_PLANNED IDX_FAILED FK_PLANNED FK_FAILED
    # shellcheck source=/dev/null
    . "$X/applied.env"
    local ic=$(( IDX_PLANNED - IDX_FAILED )) fc=$(( FK_PLANNED - FK_FAILED ))
    if [ "$IDX_FAILED" = 0 ]; then echo "| indexes | $IDX_PLANNED | $ic | ✅ |" >> "$out"; else echo "| indexes | $IDX_PLANNED | $ic | ❌ |" >> "$out"; fail=$(( fail + 1 )); fi
    if [ "$TGT_ENGINE" != mongodb ]; then
      if [ "$FK_FAILED" = 0 ]; then echo "| foreign keys | $FK_PLANNED | $fc | ✅ |" >> "$out"; else echo "| foreign keys | $FK_PLANNED | $fc | ❌ |" >> "$out"; fail=$(( fail + 1 )); fi
    fi
  fi
  local n; n="$(x_manual_count)"
  echo "| views / functions / triggers / other code | $n | 0 | ⚠️ manual — see conversion.md |" >> "$out"
  rm -f "$X/.vt" "$X/.vs" "$X/.vd"
  echo >> "$out"
  if [ "$fail" -eq 0 ]; then
    echo "**Result: PASS**$( [ "$n" -gt 0 ] && echo " — data and converted schema match; $n object(s) still need manual conversion." )" >> "$out"
    record_run "$(cat "$STATE/phase" 2>/dev/null || echo test)" validate 0 0 ok
    ok "validation passed — $out"
    [ "$n" -eq 0 ] || warn "$n object(s) still need manual conversion before the application can switch (conversion.md)"
    return 0
  fi
  echo "**Result: FAIL — $fail difference(s)**" >> "$out"
  record_run "$(cat "$STATE/phase" 2>/dev/null || echo test)" validate 0 0 "fail:$fail"
  warn "validation FAILED: $fail difference(s) — $out"
  grep '❌' "$out" | head -20 >&2
  return 1
}
