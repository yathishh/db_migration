# CDC end-to-end results

Generated 2026-11-13T13:48:12Z by `tests/cdc.sh`. Separate TLS-only source and target servers per engine;
every connection, including the replication link, in `verify` mode.

- **Data** — source and target fingerprints after cutover (people rows, MD5 of all names, sum of amounts, orders rows, sum of totals).
- **Live changes arrived** — the target's fingerprint changed after inserts/updates/deletes were made on the source during replication.
- **Replication link** — what the servers report for the replica's connection.
- **Left behind** — slots, publications, subscriptions or replica configuration remaining after cutover (must be 0).

| Engine | Tool | Data | Live changes arrived | Replication link | Left behind | |
|---|---|---|---|---|---|---|
| postgres | PASS | identical | yes | TLSv1.3 TLS_AES_256_GCM_SHA384 | 0 | ✅ |
| mariadb | PASS | identical | yes | Slave_IO_Running=Yes Master_SSL_Allowed=Yes Master_SSL_Verify_Server_Cert=Yes  | 0 | ✅ |
| mysql | PASS | identical | yes | TLSv1.3 TLS_AES_128_GCM_SHA256 | 0 | ✅ |
