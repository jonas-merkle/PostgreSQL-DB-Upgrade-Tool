# Encryption and migration

Encryption at rest, column encryption, transport encryption and backup encryption are independent. A logical migration reads data using a running database server, then restores it through SQL. It does not copy a storage engine's encryption implementation or keys.

## Supported configurations

| Source                                                      | Logical backup                            | Destination                                                                     |
| ----------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------- |
| Stock PostgreSQL on plain filesystem                        | Plain SQL or age ciphertext               | Same filesystem; plain physical files                                           |
| Stock PostgreSQL on unlocked LUKS/dm-crypt or encrypted ZFS | Plain SQL or age ciphertext               | Same encrypted filesystem, provided its encryption applies to the new directory |
| Application-encrypted columns                               | Stored ciphertext, optionally age-wrapped | Original column values preserved; retain application keys                       |
| PostgreSQL `pgcrypto` columns                               | Stored ciphertext, optionally age-wrapped | Same ciphertext and extension restored; retain column keys                      |
| Vendor-specific database TDE                                | Not supported                             | No automatic migration or plaintext fallback                                    |

The migration does not need column encryption keys. Ordinary `pg_dumpall` reads stored column values, not the output of decryption functions. CI checks both the exact ciphertext and successful decryption with a fixture key after restore. This does not cover application-specific key stores, external files, foreign data or secrets.

## Physical storage requirements

Mount and unlock encrypted storage before starting. The source root and working directory must be on the same mount and, for upgrades, share a common directory ancestor other than `/`, and nested mounts in the selected source version are rejected; the final rename keeps the target on that filesystem. For directory-level encryption, per-dataset encryption, bind mounts and unusual mount hierarchies, verify explicitly that the target and workspace inherit the desired encryption policy. The tool cannot generally infer that policy. `--require-encrypted-storage` only accepts a directly mounted dm-crypt block device; it fails closed for other topologies. This is not a certification of encrypted swap, Docker logs, snapshots or backups.

`--encrypt-backup` controls only the logical SQL file. Without it, the file is ordinary SQL (and can still be encrypted at rest by the filesystem). With it, data streams through age without a plaintext SQL dump file. Database working copies, temporary files, diagnostics, memory and swap are separate exposure surfaces. Keep all working data on appropriate encrypted storage and protect log/terminal access. Never put private keys or password files in Git.

## Database-level transparent data encryption (TDE)

Stock PostgreSQL does not offer a generic TDE storage format. Vendors can change the storage manager, table access methods, WAL, key provider and required executables. The official PostgreSQL containers used here cannot safely serve arbitrary vendor-encrypted clusters. For example, Percona `pg_tde` requires compatible Percona Server binaries and encryption configuration; it uses the `tde_heap` access method and can encrypt WAL.

This tool intentionally does not accept arbitrary custom images or silently replace encrypted access methods with plain `heap`. It checks effective shared preload libraries before starting the copied source, then checks every connectable database for extensions other than `plpgsql`/`pgcrypto` and table access methods other than `heap`. These checks are conservative and may reject benign customizations. They are not universal TDE detection: **do not run the tool on a vendor distribution even if the preflight happens to pass.**

A future vendor adapter must be implemented and tested against a specific source/target pair. At minimum it must:

1. Use compatible vendor images and tools, with a read-only original mount and isolated working copy.
2. Supply source key-provider configuration and credentials securely, with any required network access scoped to the provider.
3. Initialize the destination using the vendor's required encryption configuration before any sensitive data is restored.
4. Preserve per-database key configuration, encrypted table access methods, WAL encryption policy and any encryption-required settings. Follow vendor guidance for logical restore order and key creation; never assume copying catalog data or keys is sufficient.
5. Verify encryption state using vendor inspection tools on every relevant table and WAL, then restart and validate decryption with authorized keys. Verify that the original remains byte-for-byte intact.
6. Publish only on success, retain the old cluster and document rollback/key retention. A vendor-specific production Compose image may be necessary; a stock `postgres:<major>` image is not interchangeable.

For Percona, consult the [pg_tde documentation](https://docs.percona.com/pg-tde/), [table access methods](https://docs.percona.com/pg-tde/table-access-method.html), and [restore guidance](https://docs.percona.com/pg-tde/how-to/restore-backups.html). Generic TDE support is intentionally not advertised until a vendor adapter has passed integration tests.
