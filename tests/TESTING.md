# Testing and release verification

## Local checks

```bash
bash -n migrate.sh
bash -n tests/integration.sh
node tests/generator.test.js
```

The JavaScript tests exercise version validation, backup-only mode, age option validation, parent-mount opt-in and shell-safe quoting with adversarial paths. They do not execute the migration script.

## Docker integration tests

```bash
bash tests/integration.sh 18 19 plain host
bash tests/integration.sh 18 19 encrypted host
bash tests/integration.sh 18 19 plain 999:0
bash tests/integration.sh 18 19 encrypted 999:0
```

The optional fourth argument selects the fixture database UID/GID (`host` by default, or a numeric `UID:GID`). CI tests `host`, `999:999`, `999:0` and `1000:1000` in both modes. The fixture has a root-owned major directory (755) and a restrictive PostgreSQL data directory (700). When the database UID differs from the host, the tests assert that the host cannot read `PG_VERSION` directly.

Use a Linux host (kernel 5.12+) with local rootful Docker supporting recursive read-only bind mounts, a non-root account with Docker access and published official PostgreSQL major-version images. The fixture is disposable. CI detects the latest stable major and the preceding major on pushes and pull requests to main, manual dispatch and monthly schedules. Missing required images fail the workflow.

The integration suite checks original file fingerprints (bytes, ownership and modes), source-version auto-detection through restricted files, failed credentials, backup-only without a target, encrypted backup verification and wrong age identities, role/grant preservation, multiple databases, sequences, pgcrypto ciphertext/decryption, target PGDATA owner/mode, target startup under the original UID/GID, overwrite refusal and rollback. No production data or keys are required.

The integration suite also checks default parent-mount rejection, opt-in acceptance of an inert parent-mounted container, and continued rejection of direct and descendant mounts with the override.

## Release criteria

- Bash syntax, YAML parsing and JavaScript unit tests are local static checks.
- Live Docker integration must pass on the intended major versions before claiming runtime compatibility.
- Rehearse with a disposable copy of the actual production database and its original Compose security configuration before upgrading.
- Test `--require-encrypted-storage` on the actual encrypted mount. No universal filesystem-encryption or TDE certification is provided.
- For new major releases, confirm the official image layout, review PostgreSQL release notes and inspect CI results. Vendor-specific TDE is outside the supported scope.
