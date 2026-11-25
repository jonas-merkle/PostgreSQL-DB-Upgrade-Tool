# Testing and release verification

## Local checks

```bash
bash -n migrate.sh
bash -n tests/integration.sh
node tests/generator.test.js
```

The JavaScript tests exercise version validation, backup-only mode, age option validation and shell-safe quoting with adversarial paths. They do not execute the migration script.

## Docker integration tests

```bash
bash tests/integration.sh 18 19 plain
bash tests/integration.sh 18 19 encrypted
bash tests/integration.sh 19 20 plain
bash tests/integration.sh 19 20 encrypted
```

Use a Linux host with local rootful Docker, a non-root account with Docker access and published official major-version images. The test fixture is disposable. CI triggers on pushes and pull requests to main and manual dispatch. Future target tests defer only on a missing official image manifest.

The integration suite checks original-file fingerprints, failed credentials, backup-only without a target version, encrypted backup verification and wrong age identities, role and grant preservation, multiple databases, identity sequences, pgcrypto ciphertext equality and decryption, destination startup, overwrite refusal and original-cluster rollback. No production data or keys are required.

## Release criteria and current verification status

- Bash syntax, YAML parsing and JavaScript unit tests are local static checks.
- Live Docker integration must pass on the intended major versions before claiming runtime compatibility. No live integration result is included with this source archive.
- Rehearse with a disposable copy of the actual production database and its original Compose security configuration before upgrading.
- Test `--require-encrypted-storage` on the actual encrypted mount. No universal filesystem-encryption or TDE certification is provided.
- For new major releases, confirm the official image layout, review PostgreSQL release notes and inspect CI results. Do not advertise untested vendor TDE adapters.
