# End-to-end results

Generated 2026-11-13T12:11:08Z by `tests/e2e.sh` — PostgreSQL 16, MariaDB 11, MySQL 8.4, MongoDB 7, 1000 rows.

**Tool** = db-migrate's own assess → plan → run → validate (--checksum). **Data** = an independent
fingerprint computed by the source and target engines themselves: row count, MD5 of every text value,
MD5 of every binary value, MD5 of every timestamp, sum of the decimal column, count of true booleans,
sum of the single-precision float column. **TLS** = the protocol the source / target SERVER reported
for the tool's own sessions. Every connection ran with `verify` (encrypted + certificate and hostname
checked against a CA) against servers that refuse plain text. All three must hold for ✅.

## Migrations

| Direction | Method | Tool | Data | TLS (src / tgt) | Time | |
|---|---|---|---|---|---|---|
| postgres → postgres | native dump | PASS | identical | TLSv1.3 / TLSv1.3 | 18s | ✅ |
| postgres → mariadb | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 20s | ✅ |
| postgres → mysql | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 18s | ✅ |
| postgres → mongodb | converted | PASS | identical | TLSv1.3 / TLS, cert verified | 21s | ✅ |
| mariadb → postgres | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 18s | ✅ |
| mariadb → mariadb | native dump | PASS | identical | TLSv1.3 / TLSv1.3 | 13s | ✅ |
| mariadb → mysql | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 20s | ✅ |
| mariadb → mongodb | converted | PASS | identical | TLSv1.3 / TLS, cert verified | 18s | ✅ |
| mysql → postgres | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 18s | ✅ |
| mysql → mariadb | converted | PASS | identical | TLSv1.3 / TLSv1.3 | 19s | ✅ |
| mysql → mysql | native dump | PASS | identical | TLSv1.3 / TLSv1.3 | 14s | ✅ |
| mysql → mongodb | converted | PASS | identical | TLSv1.3 / TLS, cert verified | 22s | ✅ |
| mongodb → postgres | converted | PASS | identical | TLS, cert verified / TLSv1.3 | 13s | ✅ |
| mongodb → mariadb | converted | PASS | identical | TLS, cert verified / TLSv1.3 | 14s | ✅ |
| mongodb → mysql | converted | PASS | identical | TLS, cert verified / TLSv1.3 | 15s | ✅ |
| mongodb → mongodb | native dump | PASS | identical | TLS, cert verified / TLS, cert verified | 6s | ✅ |

## Encryption in transit

| Check | Result | |
|---|---|---|
| PostgreSQL: plain-text login (sslmode=disable) | refused | ✅ |
| PostgreSQL: TLS login, certificate verified (verify-full) | accepted | ✅ |
| MariaDB: plain-text login (--skip-ssl) | refused | ✅ |
| MariaDB: TLS login, certificate verified | accepted | ✅ |
| MySQL: plain-text login (--ssl-mode=DISABLED) | refused | ✅ |
| MySQL: TLS login, certificate verified (VERIFY_IDENTITY) | accepted | ✅ |
| MongoDB: plain-text login (no tls) | refused | ✅ |
| MongoDB: TLS login, certificate verified | accepted | ✅ |
| MongoDB: TLS with a certificate from an UNTRUSTED CA | refused | ✅ |
| db-migrate: SRC_SSL=disable without ALLOW_INSECURE_TRANSPORT | refused | ✅ |
| db-migrate: SRC_SSL=prefer (could fall back to plain text) | refused | ✅ |
| db-migrate: SRC_SSL=verify without a CA | refused | ✅ |
| db-migrate: verify against the WRONG CA (impostor server) | refused | ✅ |
| db-migrate: verify against the RIGHT CA | accepted | ✅ |
