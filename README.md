# PostgreSQL DB Upgrade Tool

A separate, one-shot Docker Compose migration project for the official Debian-based PostgreSQL Docker images, with the PostgreSQL 18+ directory convention. No changes are made to the application's Compose file, Dockhand settings, or existing version directory. All database operations and physical source copying run inside official PostgreSQL Docker containers; the host Bash launcher orchestrates Docker and filesystem publication. No PostgreSQL packages or Python are required on the host. Optional backup encryption uses a locally built Alpine-based age helper.

## Compatibility at a glance

| Feature                                           | Scope                                                                                        |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Major-version upgrade                             | Official Debian PostgreSQL images, 18+ with the versioned layout                             |
| Backup without upgrade                            | Source image only; no target version required                                                |
| Storage encryption                                | Unlocked encrypted filesystem; preserve the filesystem policy                                |
| Column encryption                                 | Application-encrypted values and `pgcrypto`; preserve ciphertext and retain application keys |
| Backup encryption                                 | Optional age public-key encryption; stream SQL without a plaintext dump file                 |
| Vendor-specific transparent data encryption (TDE) | Unsupported; no automatic plaintext fallback                                                 |
| Source preservation                               | Read-only source mount, independent working copy, verified target publication                |

See [Encryption and migration](docs/encryption.md) before migrating encrypted data. A supported design is not a guarantee of runtime compatibility; review CI and rehearse on disposable data.

## Command generator

[Open the interactive command generator](https://jonas-merkle.github.io/PostgreSQL-DB-Upgrade-Tool/) (GitHub Pages). Alternatively, open [docs/index.html](docs/index.html) locally in a browser. The generator runs entirely in the browser, does not ask for passwords or key contents, and never runs commands. Review the generated Bash command before executing it on the Docker host.

## Quick start

1. SSH into the Docker host as a non-root account with local Docker access. You do not need to own the PostgreSQL data files. Disable scheduled stack updates and stop all writers, including other stacks if applicable. In the application's Compose directory, run `docker compose down` **without `-v`**. If Dockhand holds the necessary secrets, use its stop/down action or the original Compose invocation with appropriate environment variables. Keep the application stopped throughout the migration and cutover.
2. Extract this project to a separate directory. Run:

   ```bash
   chmod +x migrate.sh
   ./migrate.sh \
     --source /srv/docker/myapp/data/db \
     --source-major 18 \
     --target-major 19 \
     --user pgadmin \
     --database appdb
   ```

   Enter the actual existing PostgreSQL superuser's password at the hidden prompt. Use the actual source version, target version, database root, SQL role and database name for your installation. The role is the PostgreSQL superuser, not your Linux account. The target image must exist and explicitly support the expected versioned layout. No `.env` file is required in this migration project; the original `.env` is never read.

3. Wait for `SUCCESS` and the manual next steps in the CLI. Inspect the private run directory and logs. The script does not start the production application.
4. Change only `image: postgres:18` to `image: postgres:19` in the original application's Compose file. Run `docker compose up -d` using its original environment and secrets (or redeploy in Dockhand). Do not change `PGDATA`, the bind mount, UID/GID or authentication settings. Your original mount remains `./data/db:/var/lib/postgresql`.
5. Check container health, authentication, application functionality and data. Keep the old directory until satisfied. Delete the old version only by your own manual decision after a separate verified backup.

## Directory layout

Before:

```
app/data/db/
└── 18/docker/PG_VERSION
```

After success:

```
app/data/
├── db/
│   ├── 18/docker/               # original, retained
│   └── 19/docker/               # verified target, cleanly shut down
└── pg-migration-18-to-19-XXXX/
    ├── cluster.sql
    ├── cluster.sql.sha256
    ├── READY.txt                # verification report written before publication
    └── logs and verification files
```

Temporary copies and credentials are removed during normal cleanup. Failed migrations do not publish partial targets or overwrite existing directories. A forced termination can leave temporary containers or files; inspect the run directory and logs before retrying. Keep the original version in all cases.

## CLI options

| Option                        | Meaning                                                                                                                                     |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `--source PATH`               | Required. Root of the original bind mount, not the `18` or `docker` subdirectory.                                                           |
| `--source-major N`            | Explicit source major, required when multiple versions remain; otherwise auto-detected.                                                     |
| `--target-major N`            | Required for migration only. Greater than source; source must be 18 or later.                                                               |
| `--user ROLE`                 | Required. Existing PostgreSQL superuser.                                                                                                    |
| `--database DB`               | Existing database for authentication smoke test (default `postgres`). Simple names only.                                                    |
| `--password-file PATH`        | Optional private password file (no group/other permissions). Otherwise hidden interactive prompt.                                           |
| `--output-parent PATH`        | Optional existing directory outside db, on the same Linux mount/filesystem. Default: parent of db.                                          |
| `--allow-parent-mounts`       | Optional. Allow running containers mounting strict ancestors of the database root, except `/`. Direct and descendant mounts remain blocked. |
| `--backup-only`               | Dump without a target version or migration.                                                                                                 |
| `--encrypt-backup`            | Encrypt the SQL dump with age.                                                                                                              |
| `--identity-file PATH`        | Private age identity; required for encrypted restore.                                                                                       |
| `--encryption-key-file PATH`  | Public age recipient list.                                                                                                                  |
| `--encryption-recipient KEY`  | Public age recipient instead of recipient file.                                                                                             |
| `--work-dir PATH`             | Alias for `--output-parent`.                                                                                                                |
| `--require-encrypted-storage` | Require supported direct dm-crypt storage.                                                                                                  |
| `--timeout SECONDS`           | Readiness/authentication timeout for each temporary server (default 300). Not a limit on dump/restore duration.                             |

Optional environment settings: `MIGRATION_TZ=Europe/Berlin`, `MIGRATION_SHM_SIZE=256m`. The tool does not install anything in the application or alter its Compose file. The temporary Compose file is invoked automatically, so do not run `docker compose up` directly in the migration project.

For unattended usage:

```bash
chmod 600 /home/user/secrets/postgres-password
./migrate.sh --source /srv/docker/myapp/data/db \
  --source-major 19 --target-major 20 --user pgadmin --database appdb \
  --password-file /home/user/secrets/postgres-password --timeout 600
```

The 19→20 example assumes the relevant official images have been published and are compatible. Major numbers are not hardcoded. If a future image changes the PGDATA layout, the preflight rejects it rather than guessing.

## Database file ownership

The PostgreSQL data directory may have a different numeric UID/GID from the host account running the tool. Restrictive PostgreSQL directory permissions are supported without modifying the source ownership or access modes. Run the launcher as a non-root user with local Docker access.

A short-lived, network-disabled filesystem helper inspects the original with a recursively read-only bind mount. The independent physical copy is normalized to the host UID/GID, and the isolated PostgreSQL servers run as that non-root user. Before publication the verified target PGDATA is assigned the original numeric UID/GID and `700` or `750` directory mode. The enclosing new major directory remains host-owned to allow an atomic rename; its mode allows the original database user to traverse it. Credentials, backups and logs remain private to the host user.

The host needs access to the database root and write access to the workspace and lock parent, and to the database root for migrations. It does not need to read the protected PGDATA. Source nested mounts, symlinks and special files are unsupported. Filesystem helpers use `alpine:latest`; the physical copy uses the official source PostgreSQL image. Docker Engine must support `bind-recursive=readonly` (Linux kernel 5.12+).

## Migration safeguards

The tool detects source ownership through an isolated filesystem helper, checks offline status, image layout, storage and destination conflicts. It mounts the original recursively read-only, copies it independently and starts isolated temporary servers. A strict logical dump and restore preserves dumpable databases, roles, grants and password hashes. It checks credentials, database and role inventories, memberships, extensions and clean shutdown, then publishes the new directory with a same-filesystem rename. The old directory is never renamed or deleted. A disabled bootstrap role may remain in the restored cluster.

### Parent directory mounts

By default, the tool rejects running containers with mounts overlapping the database root. Management containers may mount a broader directory containing multiple application stacks. If stopping such containers is impractical, explicitly add `--allow-parent-mounts` to a migration or backup command. The command generator exposes the same optional setting.

The override allows strict ancestor mounts (other than `/`) and logs warnings identifying the container and mount. Mounts of the database root itself, its descendants or `/` still cause an error, regardless of whether they are writable. Unrelated paths are unaffected. Offline, PID-file and clean-shutdown checks remain in force.

**Only enable this option if you trust every allowed container and have disabled all writers and automated redeployment.** A parent mount can expose both database files and the migration workspace, and Docker API access can permit restarting the source. The tool cannot enforce exclusive access against other processes or Docker administrators. Keep the source offline throughout the operation.

## Backup and operational logs

The logical backup includes all dumpable databases, global roles, grants and password hashes. It is private (umask 077). Logs include `dump.log`, `restore.log`, `analyze.log`, `container.log`, `cleanup.log`, control-data reports, inventory comparisons and `readiness.log`. CLI phase messages and command output show progress and errors. SQL errors or logs may contain sensitive data; protect the backup, logs, terminal history and terminal recording. Copy the completed SQL backup to independent storage and test its restore. Retaining the original data on the same disk is not protection against disk failure.

Check a completed backup:

```bash
cd /srv/docker/myapp/data/pg-migration-18-to-19-XXXX
sha256sum -c cluster.sql.sha256
cat READY.txt
```

If the CLI reports failure, do not change the original image. Fix the issue, ensure all original services remain stopped and retry. Do not delete an existing target automatically. The script refuses existing targets even if they are empty. To inspect leftover migration containers, use `docker ps -a --filter label=com.docker.compose.project=PROJECT_NAME` with the project name printed in the CLI. Stop/remove only the corresponding temporary containers and network after verifying their identities; then securely remove leftover temporary password files. Do not touch the original database directory. The script uses a host advisory lock which cannot prevent other administrators or Dockhand from starting the application; keep all services and automated deployments stopped yourself.

## Rollback

Before allowing writes on the new database, stop the application, change the image back to the source major, and start using the original environment and secrets. The original `18/docker` still exists. No directory swaps are necessary. New writes to the new major are NOT reflected in the old cluster; a rollback after writes requires a separate data reconciliation plan. Do not treat a major-version downgrade as a reverse migration.

## Requirements and limitations

- Linux kernel 5.12+, local rootful Docker Engine supporting recursive read-only bind mounts, Compose v2, Bash, GNU utilities and util-linux. Run as a non-root user with local Docker access. A writable publication root and workspace are required; original PGDATA ownership may differ. Remote Docker, rootless Docker and user namespace remapping are outside scope.
- Official Debian PostgreSQL images, version 18 or newer, with default versioned PGDATA. Source and workspace must share a Linux mount. Allow space for the source copy, dump and restored cluster.
- Only `plpgsql` and `pgcrypto` extensions are supported. Custom tablespaces, external WAL, replication, non-connectable user databases and vendor TDE are outside scope. Logical restore does not copy server configuration, physical replication state or WAL history.
- Verification is not a full row-by-row or application-level test. Review CI results and rehearse using disposable data and the production Compose security settings. Retain an independent backup; same-disk rollback does not protect against hardware failure.

References: [official PostgreSQL Docker image](https://hub.docker.com/_/postgres), [official image entrypoint](https://github.com/docker-library/postgres/blob/master/docker-entrypoint.sh), [pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html), [PostgreSQL upgrade documentation](https://www.postgresql.org/docs/current/upgrading.html).

## Continuous integration

GitHub Actions runs on pushes to `main`, pull requests targeting `main`, manual dispatch and on the first day of each month at 04:00 UTC. It detects the latest stable PostgreSQL major from `postgres:latest` and tests migration from the immediately preceding major. Missing required images, an unsupported source major (below 18), and migration failures fail CI.

The matrix runs eight integration jobs covering plain and age-encrypted migrations across matching and independent database UID/GID configurations. The tests check source bytes, ownership and permission modes, target PGDATA ownership, backup-only operation, credentials, data, encryption, roles, grants, rollback and overwrite refusal. No production data is used. Dependabot checks GitHub Actions dependencies monthly.

Run locally on a compatible Docker host as a non-root user:

```bash
bash -n migrate.sh
bash -n tests/integration.sh
node tests/generator.test.js
bash tests/integration.sh 18 19 plain
bash tests/integration.sh 18 19 encrypted
```

Adjust the PostgreSQL major versions as required. See [testing documentation](tests/TESTING.md) for the full test matrix.

### Image tagging policy

Version detection uses `postgres:latest`. Migration and test containers use `postgres:<major>` (for example `postgres:18` and `postgres:19`). These floating major tags track the newest minor release within the requested major when pulled. Using `postgres:latest` for both servers would select the same major and cannot reliably test or perform a major-version upgrade. The filesystem helper and optional age helper use `alpine:latest`. The workflow uses the GitHub-hosted `ubuntu-latest` runner; GitHub Actions themselves use versioned action references, not Docker tags.

## Encrypted storage and encrypted SQL backups

Standard PostgreSQL on an unlocked LUKS/dm-crypt or encrypted ZFS filesystem works without changing the database image. Mount/unlock the filesystem before starting. This is **not** support for third-party PostgreSQL TDE distributions. Application-encrypted columns remain encrypted as stored; retain application keys. The `pgcrypto` extension is supported by design and covered by integration tests that check exact ciphertext and successful decryption after restoration. Retain application encryption keys. See the [encryption guide](docs/encryption.md) for supported configurations and vendor TDE limitations.

### Generate an age identity (once)

The optional encryption helper is built locally from `docker/Dockerfile.age`, using `alpine:latest` and Alpine's packaged age utility. No age installation on the host is required. PostgreSQL images still use major-specific tags because using `postgres:latest` for both would defeat the upgrade.

```bash
umask 077
mkdir -p "$HOME/.config/pg-upgrade"
KEY="$HOME/.config/pg-upgrade/age-identity.txt"
# Do not overwrite an existing identity.
( set -o noclobber; docker build --pull -t pg-upgrade-age:latest -f docker/Dockerfile.age docker &&
  docker run --rm --network none --entrypoint age-keygen pg-upgrade-age:latest > "$KEY" )
chmod 600 "$KEY"
```

Store a separate, protected backup of the identity. Losing it makes the encrypted SQL backup unrecoverable. Do not commit it. Only native, unencrypted age identity files are supported for unattended use; interactive passphrase-protected identities and hardware plugins are not supported. The migration process must be able to read the identity to restore the SQL stream.

### Run an encrypted migration

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 --target-major 19 \
  --user pgadmin --database appdb \
  --encrypt-backup --identity-file "$KEY"
```

The tool derives the public recipient from the identity unless you supply `--encryption-recipient` or `--encryption-key-file`. It checks the key pair before copying the source, streams the dump into age and decrypts directly into the restore. No plaintext SQL dump file is created. The ciphertext checksum is stored in `cluster.sql.age.sha256`.

### Working storage and confidentiality

Use `--work-dir` (alias for `--output-parent`) for an existing directory outside db on the same filesystem mount. `--require-encrypted-storage` checks only directly mounted dm-crypt devices; ZFS and other layouts require independent verification. Protect temporary physical copies, logs, credentials, Docker logs and swap separately from the SQL backup. See the [encryption guide](docs/encryption.md) for details.

### Backup-only mode

The same source-copy safeguards apply, but no target is published. Backup-only uses the source-version tools and only starts a temporary source container. No target version or image is required; existing version directories are unaffected. A public recipient alone is sufficient for backup-only mode (without an identity the tool cannot verify decryption).

```bash
./migrate.sh --source /srv/docker/myapp/data/db \
  --source-major 18 --user pgadmin \
  --backup-only --encrypt-backup --encryption-recipient age1YOUR_PUBLIC_RECIPIENT
```

On success, keep the original Compose image unchanged. The SQL dump is a clean/replace dump containing destructive DROP commands; restore only into an isolated, disposable or intentionally replaced database, not an active production cluster.

### Verify an encrypted backup

From its private run directory, `sha256sum -c cluster.sql.age.sha256`. To check age authentication and decryption without writing plaintext:

```bash
docker run --rm -i --network none --user "$(id -u):$(id -g)" \
  --cap-drop ALL --security-opt no-new-privileges --read-only \
  --mount "type=bind,source=$KEY,target=/identity,readonly" \
  pg-upgrade-age:latest -d -i /identity < cluster.sql.age > /dev/null
```

Check the exit code. A full test restore is stronger than checksum/decryption verification. Keep the identity separate from backups. The CI workflow runs both plain and encrypted integration tests for the automatically detected adjacent major-version pair and ownership configurations, including wrong-key rejection, public-recipient backup-only, ciphertext checksum/decryption, lack of plaintext SQL files, original source checksums and rollback.

### Plain backup without migration

```bash
./migrate.sh --source /srv/docker/myapp/data/db --source-major 18 --user pgadmin --backup-only
```

Inspect `BACKUP.txt` and the checksum in the output directory. No new major directory is created. The source application can be restarted unchanged. Restore-test important backups on a separate disposable server.

### Operational output

Phase messages carry UTC timestamps. The CLI reports selected versions, host and original database UID/GID, private output path, project name, readiness, extension checks, dump and restore progress, checksum, cleanup and manual next steps. A nonzero exit indicates failure; do not switch the production image unless the new directory was published and verified. `READY.txt` is written before publication; it is not by itself proof that publication occurred. SQL errors and diagnostic logs may contain sensitive data even with encrypted dumps.

## License

Licensed under LGPL-3.0-only. See [LICENSE](LICENSE) and [COPYING.GPL-3](COPYING.GPL-3). PostgreSQL and Docker are separate projects with their own licenses.
