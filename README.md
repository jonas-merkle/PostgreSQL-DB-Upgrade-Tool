# PostgreSQL DB Upgrade Tool

A standalone, one-shot Docker Compose project for PostgreSQL major-version
upgrades and logical backups.

The tool uses official Debian-based PostgreSQL Docker images and supports
the PostgreSQL 18+ versioned data directory layout. It preserves the original
database directory and publishes the migrated database only after successful
restoration and verification.

No changes to the application's Docker Compose configuration are required
during migration. No PostgreSQL packages or Python installation are required
on the host.

## Features

- Automated PostgreSQL major-version upgrades.
- Logical backups using `pg_dumpall`.
- Automated restoration and database verification.
- Backup-only mode without requiring a target version.
- Safe side-by-side migrations.
- Preservation of the original database directory for rollback.
- Automatic source version detection.
- Support for future PostgreSQL major versions.
- Optional age-encrypted SQL backups.
- Streaming encryption and decryption.
- Support for filesystem-encrypted databases.
- Preservation of application-encrypted and `pgcrypto`-encrypted data.
- Isolated Docker migration containers.
- Detailed CLI output and persistent migration logs.
- Automatic cleanup of temporary migration resources.
- Interactive migration command generator.
- Automated GitHub Actions integration tests.
- No dependency on Dockhand or third-party PostgreSQL migration images.

## Compatibility

| Feature                                       | Support                                     |
| --------------------------------------------- | ------------------------------------------- |
| PostgreSQL major-version upgrades             | Official Debian images, PostgreSQL 18+      |
| Backup without upgrade                        | Supported                                   |
| LUKS / dm-crypt                               | Supported when unlocked and mounted         |
| ZFS native encryption                         | Supported when unlocked and mounted         |
| Application-level encryption                  | Supported                                   |
| PostgreSQL `pgcrypto`                         | Supported                                   |
| Encrypted SQL backups                         | Optional age encryption                     |
| Third-party transparent data encryption (TDE) | Not supported                               |
| Dockhand-managed applications                 | Supported                                   |
| Original database preservation                | Read-only source mount and independent copy |

See [Encryption and migration](docs/encryption.md) for additional information.

## Requirements

- Linux host.
- Local rootful Docker Engine.
- Docker Compose v2.
- Bash.
- GNU core utilities and util-linux.
- A non-root user with Docker access.
- Access to the original database directory.
- Existing PostgreSQL superuser credentials.
- Sufficient disk space for the source copy, SQL backup and restored database.
- Available official PostgreSQL Docker images for the requested versions.

The tool supports official Debian-based PostgreSQL images using the
PostgreSQL 18+ data directory convention:

```yaml
volumes:
  - ./data/db:/var/lib/postgresql
```

The database files must be owned by the user executing the migration tool.

Remote Docker, rootless Docker and user namespace remapping are outside
the supported scope.

## Command generator

Use the interactive command generator to create a migration or backup command:

[Open the command generator](https://jonas-merkle.github.io/PostgreSQL-DB-Upgrade-Tool/)

Alternatively, open [docs/index.html](docs/index.html) locally in a browser.

The generator runs entirely in the browser, requires no backend and does not
request database passwords or encryption key contents. Review the generated
command before executing it on the Docker host.

## Quick start

### 1. Stop the application

SSH into the Docker host and navigate to the original application's
Docker Compose directory.

Disable automatic application updates and redeployments during migration.

```bash
docker compose down
```

Do not use `docker compose down -v`.

All applications accessing the database must remain stopped throughout
the migration and cutover.

For applications managed through Dockhand, stop the stack through Dockhand
if its encrypted environment variables are required.

### 2. Run the migration

Navigate to the PostgreSQL DB Upgrade Tool directory.

```bash
chmod +x migrate.sh

./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --target-major 19 \
  --user pgadmin \
  --database appdb
```

Enter the existing PostgreSQL superuser password when prompted.

The source path must point to the database root directory, not the
individual PostgreSQL version directory.

The specified database user must be an existing PostgreSQL superuser,
not the Linux system user.

No `.env` file is required for the migration project.

The script automatically manages its temporary Docker Compose environment.
Do not start the migration project's Compose file directly.

### 3. Verify the migration

Wait for the migration tool to report `SUCCESS`.

Review the generated verification report and migration logs.

The tool does not automatically start the original application.

### 4. Update the application

Change only the PostgreSQL image tag in the original application's
Compose file.

Before:

```yaml
image: postgres:18
```

After:

```yaml
image: postgres:19
```

Keep the existing volume configuration, environment variables, secrets,
network settings, authentication settings and UID/GID unchanged.

### 5. Start the application

```bash
docker compose up -d
```

Alternatively, redeploy the original stack through Dockhand.

Verify database health, application connectivity and application data.

### 6. Remove the old version manually

Keep the original PostgreSQL version directory until the new database
has been thoroughly verified.

The migration tool never automatically deletes the original database.

Only remove the old version after confirming that the application works
correctly and an independent backup is available.

## Directory structure

Before migration:

```text
app/data/db/
└── 18/
    └── docker/
        ├── PG_VERSION
        ├── base/
        ├── global/
        └── pg_wal/
```

After successful migration:

```text
app/data/
├── db/
│   ├── 18/
│   │   └── docker/
│   └── 19/
│       └── docker/
└── pg-migration-18-to-19-XXXX/
    ├── cluster.sql
    ├── cluster.sql.sha256
    ├── READY.txt
    ├── dump.log
    ├── restore.log
    ├── analyze.log
    ├── container.log
    └── cleanup.log
```

The original version remains untouched.

The migrated version is published only after successful restoration,
verification and clean database shutdown.

Failed migrations do not intentionally publish partially restored
databases or overwrite existing version directories.

Unexpected termination or power loss may leave temporary migration
resources that require manual cleanup.

## CLI options

| Option                        | Description                                                                |
| ----------------------------- | -------------------------------------------------------------------------- |
| `--source PATH`               | Required. Original database root directory.                                |
| `--source-major N`            | Source major version. Automatically detected when only one version exists. |
| `--target-major N`            | Target major version. Required for migration only.                         |
| `--user ROLE`                 | Required. Existing PostgreSQL superuser.                                   |
| `--database DB`               | Existing database for connection verification. Default: `postgres`.        |
| `--password-file PATH`        | Optional password file. Otherwise, prompt interactively.                   |
| `--output-parent PATH`        | Existing directory for migration output.                                   |
| `--work-dir PATH`             | Alias for `--output-parent`.                                               |
| `--backup-only`               | Create a logical backup without upgrading.                                 |
| `--encrypt-backup`            | Encrypt the SQL backup using age.                                          |
| `--identity-file PATH`        | Private age identity for decryption.                                       |
| `--encryption-key-file PATH`  | Public age recipient file.                                                 |
| `--encryption-recipient KEY`  | Public age recipient key.                                                  |
| `--require-encrypted-storage` | Require supported direct dm-crypt storage.                                 |
| `--timeout SECONDS`           | Temporary database readiness timeout. Default: 300 seconds.                |

When multiple PostgreSQL version directories exist, `--source-major`
must be specified explicitly.

The target version must be greater than the source version.

The working directory must reside outside the database root and on
the same Linux filesystem mount to allow atomic publication.

The timeout controls database startup and authentication readiness.
It does not limit the duration of a dump or restore.

### Environment variables

Optional environment settings:

```dotenv
MIGRATION_TZ=Europe/Berlin
MIGRATION_SHM_SIZE=256m
```

The original application's `.env` file is never read or modified.

## Usage examples

### Standard migration

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --target-major 19 \
  --user pgadmin \
  --database appdb
```

### Unattended migration

Protect the password file:

```bash
chmod 600 /home/user/secrets/postgres-password
```

Run the migration:

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --target-major 19 \
  --user pgadmin \
  --database appdb \
  --password-file /home/user/secrets/postgres-password \
  --timeout 600
```

Passwords are not supplied as command-line arguments.

### Future PostgreSQL versions

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 19 \
  --target-major 20 \
  --user pgadmin \
  --database appdb
```

Major versions are not hardcoded into the migration tool.

Future upgrades require available official PostgreSQL images and
compatibility with the expected data directory layout.

Review PostgreSQL release notes and CI results before upgrading.

## Backup-only mode

The tool can create a logical backup without performing a major-version
upgrade.

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --user pgadmin \
  --database appdb \
  --backup-only
```

Backup-only mode:

- Uses only the source PostgreSQL image.
- Does not require a target version.
- Does not create a new PostgreSQL version directory.
- Preserves the original database.
- Supports optional backup encryption.

The original application can be restarted without changing its
Docker Compose configuration.

The application must still be stopped while the source database is copied.

The SQL backup includes dumpable databases, roles, permissions and
password hashes.

The generated dump contains destructive DROP commands intended for
a clean replacement restore. Restore it only into an isolated,
disposable or intentionally replaced database.

## Encryption

Database storage encryption and SQL backup encryption are independent.

| Source storage | SQL backup  | Migrated storage |
| -------------- | ----------- | ---------------- |
| Unencrypted    | Unencrypted | Unencrypted      |
| Unencrypted    | Encrypted   | Unencrypted      |
| Encrypted      | Unencrypted | Encrypted        |
| Encrypted      | Encrypted   | Encrypted        |

This assumes that filesystem-encrypted databases are restored onto
storage with the same encryption policy.

### Filesystem encryption

Standard PostgreSQL databases stored on encrypted filesystems, such as
LUKS or encrypted ZFS, can be migrated once the filesystem is unlocked
and mounted.

The operating system transparently handles encryption and decryption.

The migrated database retains filesystem encryption when published
onto storage governed by the same encryption policy.

The migration tool does not need the filesystem encryption key.

Temporary physical database copies, credentials, logs and other
migration files must also be protected.

### Database-level encryption

Application-encrypted values and PostgreSQL `pgcrypto` ciphertext
are preserved during logical migration.

Application encryption keys must be retained separately.

Third-party PostgreSQL distributions implementing transparent data
encryption (TDE) are not supported.

The tool performs checks for unsupported extensions, preload libraries
and storage access methods. These checks are not a universal TDE detector.

It does not intentionally fall back to unencrypted database storage
when encountering unsupported encryption configurations.

See [Encryption and migration](docs/encryption.md) for details.

### Generate an age identity

The optional age helper is built locally using Docker.

No age installation is required on the host.

```bash
umask 077

mkdir -p "$HOME/.config/pg-upgrade"

KEY="$HOME/.config/pg-upgrade/age-identity.txt"

(
  set -o noclobber

  docker build --pull \
    -t pg-upgrade-age:latest \
    -f docker/Dockerfile.age docker &&

  docker run --rm \
    --network none \
    --entrypoint age-keygen \
    pg-upgrade-age:latest > "$KEY"
)

chmod 600 "$KEY"
```

Do not overwrite an existing identity.

Keep a secure, independent backup of the private identity.

Losing the private identity makes encrypted backups unrecoverable.

Only native, unencrypted age identity files are supported for unattended
operation. Interactive passphrase-protected identities and hardware
plugins are outside the supported scope.

### Encrypted migration

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --target-major 19 \
  --user pgadmin \
  --database appdb \
  --encrypt-backup \
  --identity-file "$HOME/.config/pg-upgrade/age-identity.txt"
```

The tool derives the public recipient from the supplied private identity
unless an explicit recipient is provided.

It verifies encryption and decryption before beginning the migration.

The SQL dump is streamed directly into age and decrypted directly
into PostgreSQL during restoration.

No plaintext SQL dump file is written to disk.

The output includes:

```text
cluster.sql.age
cluster.sql.age.sha256
```

### Encrypted backup only

A public age recipient is sufficient when creating a backup without
restoring it.

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --user pgadmin \
  --backup-only \
  --encrypt-backup \
  --encryption-key-file /secure/recipients.txt
```

Alternatively, provide an explicit public recipient:

```bash
./migrate.sh \
  --source /srv/docker/myapp/data/db \
  --source-major 18 \
  --user pgadmin \
  --backup-only \
  --encrypt-backup \
  --encryption-recipient age1YOUR_PUBLIC_RECIPIENT
```

The private identity does not need to be present during backup-only
operation.

Without the private identity, the tool cannot verify successful
decryption of the completed backup.

### Require encrypted storage

```bash
./migrate.sh \
  --source /mnt/encrypted/myapp/data/db \
  --source-major 18 \
  --target-major 19 \
  --user pgadmin \
  --database appdb \
  --work-dir /mnt/encrypted/migrations \
  --require-encrypted-storage \
  --encrypt-backup \
  --identity-file /secure/age-identity.txt
```

The automated storage check supports directly mounted dm-crypt devices.

Encrypted ZFS, complex LVM configurations and other storage technologies
require independent verification.

The tool rejects storage configurations that it cannot verify when
`--require-encrypted-storage` is enabled.

## Backup verification

Verify an unencrypted backup:

```bash
sha256sum -c cluster.sql.sha256
```

Verify an encrypted backup:

```bash
sha256sum -c cluster.sql.age.sha256
```

Verify encrypted backup decryption without writing plaintext:

```bash
KEY="$HOME/.config/pg-upgrade/age-identity.txt"

docker run --rm -i \
  --network none \
  --user "$(id -u):$(id -g)" \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --mount "type=bind,source=$KEY,target=/identity,readonly" \
  pg-upgrade-age:latest \
  -d -i /identity < cluster.sql.age > /dev/null
```

Check the command's exit status.

A successful checksum or decryption check does not replace a complete
test restoration.

Store important backups on independent storage.

## Migration procedure

The migration tool automatically performs the following operations:

1. Validate command-line parameters.
2. Check Docker availability and source directory ownership.
3. Check that the source database is stopped.
4. Detect or validate the source PostgreSQL major version.
5. Check image availability and expected data directory layout.
6. Verify that the destination does not already exist.
7. Create a private migration workspace.
8. Copy the original database through a read-only mount.
9. Check the source database shutdown state.
10. Start isolated temporary PostgreSQL containers.
11. Verify source authentication and supported extensions.
12. Create a cluster-wide logical backup.
13. Restore the backup into the target database.
14. Verify databases, roles, grants, credentials and extension inventory.
15. Update database statistics.
16. Shut down temporary database containers cleanly.
17. Publish the verified target version directory.
18. Clean up temporary containers, credentials and working copies.
19. Report the manual cutover steps.

The original database directory is never intentionally modified,
renamed or deleted.

The migration checks do not replace application-level testing or
full data validation.

## Logging and error handling

The tool provides detailed, timestamped CLI output covering:

- Selected PostgreSQL versions.
- Host UID/GID.
- Migration workspace and Docker project name.
- Preflight checks.
- Database startup and readiness.
- Extension and encryption checks.
- Dump and restore progress.
- Database verification.
- Backup checksums.
- Temporary resource cleanup.
- Manual next steps.

Diagnostic output is retained in the private migration directory.

If an operation fails, the tool exits with a nonzero exit code.

Do not change the original application's PostgreSQL image after
a failed migration.

Correct the reported problem and retry after checking that no
temporary migration containers remain.

The tool refuses to overwrite an existing target version directory,
even if that directory is empty.

`READY.txt` is written before publication and is not sufficient on its
own to prove that the target directory was successfully published.

Use the final CLI result and inspect the published directory.

### Inspect leftover containers

If the migration process is unexpectedly interrupted:

```bash
docker ps -a \
  --filter label=com.docker.compose.project=PROJECT_NAME
```

Use the migration project name printed in the CLI output.

Inspect and remove only the corresponding temporary migration
resources.

Protect or securely remove leftover temporary credentials.

Do not remove the original database directory.

The host advisory lock cannot prevent another administrator or
Dockhand from starting the original application. Keep all original
services and automated deployments stopped during migration.

## Rollback

Because the original database directory is retained, no directory
swapping is required for rollback.

Stop the application:

```bash
docker compose down
```

Change the image back to the original major version:

```yaml
image: postgres:18
```

Start the application:

```bash
docker compose up -d
```

PostgreSQL will use the original version-specific data directory.

**Important:** Changes made to the upgraded database are not reflected
in the original database.

Rollback after accepting production writes requires a separate data
reconciliation plan.

A PostgreSQL major-version downgrade is not supported as a reverse
migration.

## Security

The migration tool uses the following safeguards:

- Read-only access to the original database.
- Independent source database copies.
- Isolated internal Docker networks.
- No published database ports.
- No privileged containers.
- No Docker socket mounted into migration containers.
- Restricted container capabilities.
- Non-root database processes.
- Restricted temporary credential files.
- Private migration workspaces and backups.
- Optional age-encrypted SQL backups.
- Same-filesystem publication of the verified target.
- Explicit prevention of destination overwrites.

Backups include sensitive database contents and role password hashes.

Logs, Docker logs, terminal recordings, temporary physical copies
and swap may also contain sensitive information.

Backup encryption does not independently encrypt these resources.

Use encrypted working storage where confidentiality is required.

## Continuous integration

GitHub Actions runs automatically on:

- Pushes to `main`.
- Pull requests targeting `main`.
- Monthly scheduled compatibility checks.
- Manual workflow execution.

The scheduled workflow runs on the first day of each month at
04:00 UTC.

### Automatic PostgreSQL version detection

CI automatically detects the latest stable PostgreSQL major version
using the official `postgres:latest` image.

The immediately preceding major version is selected as the migration
source.

Both plain and age-encrypted migrations are tested.

| Latest PostgreSQL version | Tested migration  |
| ------------------------- | ----------------- |
| 19                        | 18 → 19           |
| 20                        | 19 → 20           |
| 21                        | 20 → 21           |
| Future releases           | Previous → Latest |

No manual CI version updates are required when a new PostgreSQL
major version becomes available.

The detected source version must be PostgreSQL 18 or newer.

Missing required Docker images and failed migration tests cause
the workflow to fail.

### Integration tests

The integration suite uses disposable Docker containers and verifies:

- Real PostgreSQL major-version migrations.
- Plain and encrypted SQL backups.
- Backup-only operation.
- Successful database restoration.
- Multiple databases and representative data.
- Role, credential and permission preservation.
- Identity sequence preservation.
- `pgcrypto` ciphertext preservation and decryption.
- Incorrect password handling.
- Incorrect encryption identity handling.
- Unsupported configuration rejection.
- Original database file preservation.
- Existing target overwrite prevention.
- Successful target database startup.
- Rollback to the original PostgreSQL version.

No production data, passwords or encryption keys are required.

### Dependency management

The workflow uses GitHub-hosted `ubuntu-latest` runners and
versioned GitHub Actions dependencies.

Dependabot checks GitHub Actions dependencies monthly and
automatically opens pull requests for available updates.

### Local testing

Run the static checks:

```bash
bash -n migrate.sh
bash -n tests/integration.sh
node tests/generator.test.js
```

Run the Docker integration tests:

```bash
bash tests/integration.sh 18 19 plain
bash tests/integration.sh 18 19 encrypted
```

Adjust the PostgreSQL major versions as required.

See [testing documentation](tests/TESTING.md) for additional
information and release verification requirements.

### Image tagging policy

The CI workflow uses `postgres:latest` to detect the latest
stable PostgreSQL major version.

Migration and integration test containers use explicit major-version
tags, such as `postgres:18` and `postgres:19`.

These tags track the latest available minor release within the
respective major version when pulled.

Using `postgres:latest` for both source and target containers would
prevent reliable major-version migrations.

The optional age encryption helper uses `alpine:latest`.

GitHub Actions use versioned action references maintained through
Dependabot.

## Limitations

- PostgreSQL versions earlier than 18 are not supported.
- Only official Debian-based PostgreSQL images are supported.
- Only the `plpgsql` and `pgcrypto` extensions are supported.
- Vendor-specific TDE distributions are not supported.
- Custom tablespaces and external WAL directories are outside scope.
- Physical replication and replication state are outside scope.
- Non-connectable user databases are outside scope.
- Server configuration files are not transferred by logical restoration.
- Automatic storage encryption verification is limited to supported
  direct dm-crypt configurations.
- Sufficient storage is required for the working copy, backup and
  restored database.
- Future PostgreSQL image layout changes may require tool updates.
- Verification does not constitute a complete application-level or
  row-by-row data validation.
- Retaining the original database on the same disk does not protect
  against hardware failure.

Always review CI results, create an independent backup and rehearse
the migration using disposable data before upgrading a production
database.

## References

- [Official PostgreSQL Docker image](https://hub.docker.com/_/postgres)
- [PostgreSQL Docker image entrypoint](https://github.com/docker-library/postgres/blob/master/docker-entrypoint.sh)
- [PostgreSQL upgrade documentation](https://www.postgresql.org/docs/current/upgrading.html)
- [PostgreSQL pg_dumpall documentation](https://www.postgresql.org/docs/current/app-pg-dumpall.html)
- [age encryption](https://github.com/FiloSottile/age)
- [Docker Compose documentation](https://docs.docker.com/compose/)

## License

This project is licensed under the GNU Lesser General Public License
v3.0 only (`LGPL-3.0-only`).

See [LICENSE](LICENSE) and [COPYING.GPL-3](COPYING.GPL-3) for the
complete license terms.

PostgreSQL, Docker and age are separate projects distributed under
their respective licenses.
