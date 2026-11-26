#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# Strict mode includes pipeline failures (dump, encryption, decryption, restore).
# The host only orchestrates containers and publishes a verified directory.
set -Eeuo pipefail
umask 077 # Restrict dumps, logs and temporary credentials.

usage() {
  cat <<'HELP'
Usage: ./migrate.sh --source /absolute/path/to/data/db --source-major 18 --target-major 19 \
                    --user pgadmin [--database appdb] [--password-file /secure/file] \
                    [--output-parent /path] [--timeout 300] \
                    [--encrypt-backup --identity-file /secure/age-key.txt \
                     [--encryption-key-file /path/recipients.txt | --encryption-recipient age1...]] \
                    [--require-encrypted-storage] [--backup-only]

Run as a non-root host user with local Docker access and writable publication parent.
Database ownership is detected automatically and preserved on the published target.
Backup-only requires no target version or target image.
Supports stock PostgreSQL and pgcrypto column encryption; vendor TDE is not supported.
Stop the original PostgreSQL and all writers before running. No automatic cutover.
If --password-file is omitted, the password is requested without echoing it.
A successful run publishes <target-major>/docker beside the untouched source.
Logs and SQL backup remain in a private sibling run directory.
If several source versions exist, --source-major is mandatory.
Only official Debian PostgreSQL major-version images, version 18 or newer, are supported.
--work-dir aliases --output-parent (same mount as database root).
Encrypted migration requires an age identity file; backup-only may use a public recipient alone.
--require-encrypted-storage checks for a directly mounted dm-crypt device (not ZFS).
HELP
}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[%s] ==> %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
# Parse configuration without sourcing user-controlled shell files.
SOURCE_PATH= SOURCE_MAJOR= TARGET_MAJOR= SOURCE_USER= SOURCE_DB=postgres PASSWORD_FILE= OUTPUT_PARENT= TIMEOUT=300
ENCRYPT=0 REQUIRE_ENCRYPTED=0 BACKUP_ONLY=0 IDENTITY_FILE= RECIPIENT_FILE= RECIPIENT=
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0;;
    --encrypt-backup) ENCRYPT=1; shift;;
    --require-encrypted-storage) REQUIRE_ENCRYPTED=1; shift;;
    --backup-only) BACKUP_ONLY=1; shift;;
    --source|--source-major|--target-major|--user|--database|--password-file|--output-parent|--work-dir|--timeout|--identity-file|--encryption-key-file|--encryption-recipient)
      (($# >= 2)) || fail "Missing value for $1"
      case "$1" in
        --source) SOURCE_PATH=$2;; --source-major) SOURCE_MAJOR=$2;; --target-major) TARGET_MAJOR=$2;; --user) SOURCE_USER=$2;;
        --database) SOURCE_DB=$2;; --password-file) PASSWORD_FILE=$2;; --output-parent|--work-dir) OUTPUT_PARENT=$2;; --timeout) TIMEOUT=$2;;
        --identity-file) IDENTITY_FILE=$2;; --encryption-key-file) RECIPIENT_FILE=$2;; --encryption-recipient) RECIPIENT=$2;;
      esac; shift 2;;
    *) fail "Unknown option: $1";;
  esac
done
[[ -n $SOURCE_PATH && -n $SOURCE_USER ]] || { usage; exit 2; }
[[ -n $SOURCE_USER && $SOURCE_USER != -* && $SOURCE_USER != *$'\n'* && $SOURCE_USER != *$'\r'* ]] || fail 'Invalid source role.'
[[ $SOURCE_DB =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail 'Use a simple database name for --database (not a connection string).'
[[ $TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || fail 'Invalid timeout.'
# Validate key paths before Docker is started.
if ((ENCRYPT)); then
  [[ -z $RECIPIENT_FILE || -z $RECIPIENT ]] || fail 'Choose one recipient input.'
  if (( ! BACKUP_ONLY )); then [[ -n $IDENTITY_FILE ]] || fail 'Encrypted restore requires --identity-file.'; fi
  [[ -n $IDENTITY_FILE || -n $RECIPIENT_FILE || -n $RECIPIENT ]] || fail 'Provide an age identity or public recipient.'
  if [[ -n $IDENTITY_FILE ]]; then
    IDENTITY_FILE=$(realpath -e -- "$IDENTITY_FILE")
    [[ -f $IDENTITY_FILE && -r $IDENTITY_FILE && $(stat -Lc %a "$IDENTITY_FILE") =~ ^[0-7]00$ ]] || fail 'Age identity must be a readable private file (chmod 600).'
  fi
  if [[ -n $RECIPIENT_FILE ]]; then RECIPIENT_FILE=$(realpath -e -- "$RECIPIENT_FILE"); [[ -f $RECIPIENT_FILE && -r $RECIPIENT_FILE ]] || fail 'Recipient file not readable.'; fi
  if [[ -n $RECIPIENT ]]; then [[ $RECIPIENT =~ ^age1[0-9a-z]+$ ]] || fail 'Use a native age public recipient.'; fi
else
  [[ -z $IDENTITY_FILE && -z $RECIPIENT_FILE && -z $RECIPIENT ]] || fail 'Encryption options require --encrypt-backup.'
fi
for cmd in docker realpath stat find mktemp od tr diff sha256sum grep flock mv tee sync cut findmnt; do command -v "$cmd" >/dev/null || fail "Missing command: $cmd"; done
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SOURCE_PATH=$(realpath -e -- "$SOURCE_PATH")
[[ -d $SOURCE_PATH && $SOURCE_PATH != / ]] || fail 'Invalid source directory.'
RUN_UID=$(id -u); RUN_GID=$(id -g)
[[ $RUN_UID != 0 ]] || fail 'Do not run as root; use a non-root account with Docker access.'
[[ -z $SOURCE_MAJOR || $SOURCE_MAJOR =~ ^[1-9][0-9]{1,2}$ ]] || fail 'Invalid source major.'
# Validate the daemon before granting any helper access to host paths.
docker compose version >/dev/null
endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
[[ $endpoint == unix://* ]] || fail 'A local Unix-socket Docker daemon is required.'
security=$(docker info --format '{{json .SecurityOptions}}')
[[ $security != *rootless* && $security != *userns* ]] || fail 'Rootless Docker and user namespace remapping are not supported.'
# Lock outside the database tree. The host needs access to the parent, not PGDATA.
LOCK_FILE="$(dirname "$SOURCE_PATH")/.pg-migration-$(printf '%s' "$SOURCE_PATH" | sha256sum | cut -c1-24).lock"
exec 9>"$LOCK_FILE"
flock -n 9 || fail 'Another migration holds the lock for this data directory.'
log 'Pulling isolated filesystem helper (Alpine latest)'
docker pull alpine:latest >&2
HELPER=(docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges --read-only)
# Mount the original recursively read-only. Require kernel/Engine support; never
# fall back to a potentially writable nested mount.
SOURCE_MOUNT=(--mount "type=bind,source=$SOURCE_PATH,target=/original,readonly,bind-recursive=readonly")
source_probe() {
  "${HELPER[@]}" "${SOURCE_MOUNT[@]}" --entrypoint sh alpine:latest -eu -c '
    die() { echo "ERROR: $*" >&2; exit 1; }
    major=$1
    if [ -z "$major" ]; then
      count=0
      for d in /original/*; do
        [ ! -L "$d" ] && [ -d "$d" ] || continue
        n=${d##*/}
        case "$n" in *[!0-9]*|"") continue;; esac
        [ ! -L "$d/docker" ] && [ -d "$d/docker" ] && [ -f "$d/docker/PG_VERSION" ] || continue
        count=$((count+1)); major=$n
      done
      [ "$count" = 1 ] || die "Multiple or no clusters found; specify --source-major explicitly."
    fi
    parent=/original/$major; data=$parent/docker
    [ ! -L "$parent" ] && [ ! -L "$data" ] && [ -d "$data" ] || die "Expected non-symlinked source directory: $data"
    [ ! -L "$data/PG_VERSION" ] && [ -f "$data/PG_VERSION" ] || die "Missing or invalid source PG_VERSION."
    actual=$(cat "$data/PG_VERSION") || die "Cannot read source PG_VERSION."
    [ "$actual" = "$major" ] || die "Source PG_VERSION ($actual) does not match $major."
    # Reject any nested mount in the selected version tree (including bind mounts).
    ! grep -Eq "^[^ ]+ [^ ]+ [^ ]+ [^ ]+ $parent(/| )" /proc/self/mountinfo || die "Nested mounts in source version are unsupported."
    [ ! -e "$data/postmaster.pid" ] || die "postmaster.pid exists; stop PostgreSQL cleanly first. Do not delete it manually."
    [ ! -e "$data/standby.signal" ] && [ ! -e "$data/recovery.signal" ] || die "Standby/recovery clusters are unsupported."
    bad=$(find "$data" ! -type d ! -type f -print -quit) || die "Cannot inspect source tree."
    [ -z "$bad" ] || die "Symlinks and special files in PGDATA are unsupported: $bad"
    printf "%s " "$major"
    stat -c "%u %g %a" "$data" | tr "\n" " "
    stat -c "%u %g %a" "$parent"
  ' sh "$1"
}
metadata=$(source_probe "$SOURCE_MAJOR") || fail 'Read-only source inspection failed; check the diagnostic above.'
read -r SOURCE_MAJOR DATA_UID DATA_GID DATA_MODE PARENT_UID PARENT_GID PARENT_MODE extra <<< "$metadata"
[[ -z $extra && $SOURCE_MAJOR =~ ^[1-9][0-9]{1,2}$ && $SOURCE_MAJOR -ge 18 ]] || fail 'Require source >= 18.'
for n in "$DATA_UID" "$DATA_GID" "$PARENT_UID" "$PARENT_GID"; do [[ $n =~ ^[0-9]+$ ]] || fail 'Invalid ownership metadata.'; done
[[ $DATA_UID != 0 && $DATA_MODE =~ ^(700|750)$ && $PARENT_MODE =~ ^[0-7]{3,4}$ ]] || fail 'Unsupported PGDATA owner or mode (require non-root owner and 700/750).'
if ((BACKUP_ONLY)); then TARGET_MAJOR=$SOURCE_MAJOR; else
  [[ $TARGET_MAJOR =~ ^[1-9][0-9]{1,2}$ && $TARGET_MAJOR -gt $SOURCE_MAJOR ]] || fail 'Require target > source.'
fi
SOURCE_DATA="$SOURCE_PATH/$SOURCE_MAJOR/docker"
FINAL_DIR="$SOURCE_PATH/$TARGET_MAJOR"
if ((!BACKUP_ONLY)); then
  [[ -w $SOURCE_PATH && -x $SOURCE_PATH ]] || fail 'Database root must allow publishing a new version directory; no access to PGDATA itself is required.'
  [[ ! -e $FINAL_DIR && ! -L $FINAL_DIR ]] || fail "Target already exists: $FINAL_DIR; refusing to overwrite it."
fi
OUTPUT_PARENT=${OUTPUT_PARENT:-$(dirname -- "$SOURCE_PATH")}
OUTPUT_PARENT=$(realpath -e -- "$OUTPUT_PARENT")
[[ -d $OUTPUT_PARENT && $OUTPUT_PARENT != "$SOURCE_PATH" && $OUTPUT_PARENT != "$SOURCE_PATH/"* ]] || fail 'Output must be outside the source directory.'
[[ $(stat -c %d "$OUTPUT_PARENT") == "$(stat -c %d "$SOURCE_PATH")" ]] || fail 'Output and database root must be on the same filesystem for atomic publication.'
output_mount=$(findmnt -n -o ID -T "$OUTPUT_PARENT") || fail 'Cannot determine workspace mount.'
source_mount=$(findmnt -n -o ID -T "$SOURCE_PATH") || fail 'Cannot determine database root mount.'
[[ -n $output_mount && $output_mount == "$source_mount" ]] || fail 'Output and database root must be on the same Linux mount for atomic publication.'
if ((REQUIRE_ENCRYPTED)); then
  command -v lsblk >/dev/null || fail 'lsblk required for encrypted storage verification.'
  for path in "$SOURCE_PATH" "$OUTPUT_PARENT"; do
    device=$(findmnt -n -o SOURCE -T "$path")
    [[ -b $device ]] || fail "Cannot verify encrypted block storage for $path ($device)."
    [[ $(lsblk -dn -o TYPE "$device") == crypt ]] || fail "Not a directly mounted dm-crypt device: $path. Cannot certify this storage configuration."
  done
  log 'Verified direct dm-crypt mount for source and migration output (not a guarantee about swap or Docker logs).'
fi
MV_OPTS=(-T -n)
if mv --help | grep -q -- '--no-copy'; then MV_OPTS+=(--no-copy); fi
check_offline() {
  local ids id mounts m canonical
  ids=$(docker ps -q) || fail 'Cannot enumerate Docker containers.'
  for id in $ids; do
    mounts=$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$id") || fail 'Cannot inspect Docker mounts.'
    while IFS= read -r m; do
      [[ -n $m ]] || continue
      canonical=$(realpath -m -- "$m")
      if [[ $canonical == / || $canonical == "$SOURCE_PATH" || $canonical == "$SOURCE_PATH/"* || $SOURCE_PATH == "$canonical/"* ]]; then
        fail "Running container $id mounts the source or an overlapping directory ($m). Stop it first."
      fi
    done <<< "$mounts"
  done
  local current
  current=$(source_probe "$SOURCE_MAJOR") || fail 'Source is not offline or no longer valid.'
  [[ $current == "$metadata" ]] || fail 'Source ownership, permissions or version changed unexpectedly.'
}
log "Preflight: PostgreSQL $SOURCE_MAJOR; source root $SOURCE_PATH; host UID/GID $RUN_UID:$RUN_GID; original PGDATA UID/GID $DATA_UID:$DATA_GID"
if ((BACKUP_ONLY)); then log 'Mode: backup only (no target database)'; else log "Mode: upgrade to PostgreSQL $TARGET_MAJOR"; fi
log 'Checking for running containers with overlapping mounts and PostgreSQL PID file'
check_offline
# Never accept passwords as command arguments; file or hidden prompt only.
if [[ -n $PASSWORD_FILE ]]; then
  [[ -f $PASSWORD_FILE && -r $PASSWORD_FILE ]] || fail 'Password file is not readable.'
  [[ $(stat -Lc %a "$PASSWORD_FILE") =~ ^[0-7]00$ ]] || fail 'Password file must not grant group or other permissions (chmod 600).'
  password=$(cat -- "$PASSWORD_FILE")
else
  [[ -t 0 ]] || fail 'Use --password-file for noninteractive operation.'
  read -r -s -p "Password for PostgreSQL role $SOURCE_USER: " password; printf '\n' >&2
fi
[[ -n $password && $password != *$'\n'* && $password != *$'\r'* ]] || fail 'Password must be nonempty and single-line.'
# All workspaces and logs live outside the production root. The only write
# under that root is the final publication of a previously nonexistent major.
RUN_DIR=$(mktemp -d -- "$OUTPUT_PARENT/pg-migration-${SOURCE_MAJOR}-to-${TARGET_MAJOR}-XXXXXXXX")
mkdir -m 700 -- "$RUN_DIR/private" "$RUN_DIR/source" "$RUN_DIR/target"
mkdir -m 700 -- "$RUN_DIR/source/$SOURCE_MAJOR"
random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
BOOTSTRAP_ROLE="migration_$(random_hex 12)"
PROJECT="pgmigrate-$(random_hex 8)"
TARGET_INITDB_GROUP_ARG=
if [[ $DATA_MODE == 750 ]]; then TARGET_INITDB_GROUP_ARG=--allow-group-access; fi
export RUN_DIR RUN_UID RUN_GID SOURCE_MAJOR TARGET_MAJOR BOOTSTRAP_ROLE TARGET_INITDB_GROUP_ARG
export MIGRATION_TZ=${MIGRATION_TZ:-Europe/Berlin} MIGRATION_SHM_SIZE=${MIGRATION_SHM_SIZE:-256m}
DC=(docker compose --project-name "$PROJECT" --env-file /dev/null -f "$SCRIPT_DIR/compose.yaml")
started=0
published=0
cleanup() {
  local rc=$? down_ok=1
  log "Cleanup: stopping temporary services and removing disposable files (exit status $rc)"
  trap - EXIT; set +e
  if ((started)); then
    "${DC[@]}" logs --no-color > "$RUN_DIR/container.log" 2>&1
    "${DC[@]}" down --timeout 120 >> "$RUN_DIR/cleanup.log" 2>&1 || down_ok=0
  fi
  # A failure never removes a published directory, or any original data.
  if ((published)); then
    printf 'Target published: %s\n' "$FINAL_DIR" >&2
  fi
  if ((down_ok)); then
    rm -f -- "$RUN_DIR/private/source-password" "$RUN_DIR/private/bootstrap-password"
    rmdir -- "$RUN_DIR/private" 2>/dev/null
    # Only remove disposable copies inside the private run directory.
    if ! rm -rf -- "$RUN_DIR/source" "$RUN_DIR/target"; then
      # Ownership may have been restored on the staged target before a failure.
      # Mount only the disposable workspace, never the production root.
      if ! "${HELPER[@]}" --cap-add FOWNER --mount "type=bind,source=$RUN_DIR,target=/work" --entrypoint sh alpine:latest -eu -c 'rm -rf /work/source /work/target' >> "$RUN_DIR/cleanup.log" 2>&1; then
        printf 'WARNING: disposable workspace cleanup failed: %s\n' "$RUN_DIR" >&2; rc=1
      fi
    fi
    rm -f -- "$RUN_DIR/cluster.sql.part" "$RUN_DIR/cluster.sql.age.part"
  else
    printf 'WARNING: cleanup failed. Containers or secrets may remain OUTSIDE the production root. Project: %s\n' "$PROJECT" >&2; rc=1
  fi
  if ((rc)); then
    if ((published)) || [[ -d $FINAL_DIR && ! -e $RUN_DIR/target/$TARGET_MAJOR && -f $RUN_DIR/READY.txt ]]; then
      printf 'Publication may already have completed. Inspect %s and %s before restarting.\n' "$FINAL_DIR" "$RUN_DIR" >&2
    else
      printf 'Migration FAILED; no target was published by this run. Original version untouched. Diagnostics: %s\n' "$RUN_DIR" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'printf "ERROR: migration command failed at line %s (exit %s). See CLI output and %s\n" "$LINENO" "$?" "$RUN_DIR" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$password" > "$RUN_DIR/private/source-password"; unset password
random_hex 32 > "$RUN_DIR/private/bootstrap-password"
printf 'Project: %s\nOutput: %s\n' "$PROJECT" "$RUN_DIR" >&2
log 'Pulling official images and checking configuration'
"${DC[@]}" config --quiet
services=(source target)
majors=("$SOURCE_MAJOR" "$TARGET_MAJOR")
if ((BACKUP_ONLY)); then services=(source); majors=("$SOURCE_MAJOR"); fi
"${DC[@]}" pull "${services[@]}"
for major in "${majors[@]}"; do
  expected="PGDATA=/var/lib/postgresql/$major/docker"
  docker image inspect "postgres:$major" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Fx "$expected" >/dev/null || fail "postgres:$major does not advertise expected data layout."
done
BACKUP_NAME=cluster.sql
# The age helper has no network access and never writes a plaintext SQL file.
if ((ENCRYPT)); then
  BACKUP_NAME=cluster.sql.age
  log 'Building isolated age helper (Alpine latest)'
  AGE_IMAGE="pg-upgrade-age:latest"
  docker build --pull -t "$AGE_IMAGE" -f "$SCRIPT_DIR/docker/Dockerfile.age" "$SCRIPT_DIR/docker"
  AGE_RUN=(docker run --rm -i --network none --user "$RUN_UID:$RUN_GID" --cap-drop ALL --security-opt no-new-privileges --read-only)
  AGE_ENCRYPT=()
  if [[ -n $RECIPIENT_FILE ]]; then
    AGE_ENCRYPT=(--mount "type=bind,source=$RECIPIENT_FILE,target=/recipients,readonly" "$AGE_IMAGE" -R /recipients)
  elif [[ -n $RECIPIENT ]]; then
    AGE_ENCRYPT=("$AGE_IMAGE" -r "$RECIPIENT")
  else
    RECIPIENT=$("${AGE_RUN[@]}" --mount "type=bind,source=$IDENTITY_FILE,target=/identity,readonly" --entrypoint age-keygen "$AGE_IMAGE" -y /identity)
    AGE_ENCRYPT=("$AGE_IMAGE" -r "$RECIPIENT")
  fi
  if [[ -n $IDENTITY_FILE ]]; then
    AGE_DECRYPT=(--mount "type=bind,source=$IDENTITY_FILE,target=/identity,readonly" "$AGE_IMAGE" -d -i /identity)
    # Test recipient/identity compatibility before copying or starting PostgreSQL.
    [[ $(printf 'pg-upgrade-key-check' | "${AGE_RUN[@]}" "${AGE_ENCRYPT[@]}" | "${AGE_RUN[@]}" "${AGE_DECRYPT[@]}") == pg-upgrade-key-check ]] || fail 'Age recipient/identity mismatch.'
  fi
fi
check_offline
log 'Copying stopped source cluster (independent copy, not hard links)'
# Normalize only the independent copy to the host UID/GID. Temporary servers,
# credentials, age helper, and diagnostics can retain the existing host identity.
"${HELPER[@]}" --cap-add CHOWN --cap-add FOWNER "${SOURCE_MOUNT[@]}" \
  --mount "type=bind,source=$RUN_DIR/source/$SOURCE_MAJOR,target=/copy" \
  --entrypoint sh "postgres:$SOURCE_MAJOR" -eu -c '
    cp -a --reflink=auto -- "/original/$1/docker" /copy/docker
    chown -R -- "$2:$3" /copy/docker
  ' sh "$SOURCE_MAJOR" "$RUN_UID" "$RUN_GID"
check_offline
log 'Checking clean shutdown state on the copied source'
control_state() {
  docker run --rm --network none --user "$RUN_UID:$RUN_GID" --cap-drop ALL \
    --security-opt no-new-privileges --read-only \
    --mount "type=bind,source=$1,target=/check,readonly" \
    --entrypoint pg_controldata -e LC_ALL=C "postgres:$2" /check
}
control_state "$RUN_DIR/source/$SOURCE_MAJOR/docker" "$SOURCE_MAJOR" | tee "$RUN_DIR/source-control.log"
grep -Eq '^Database cluster state:[[:space:]]+shut down$' "$RUN_DIR/source-control.log" || fail 'Source was not cleanly shut down.'
# Do not bypass a vendor storage manager or encryption-related preload. A stock
# server cannot safely read a TDE cluster. Check effective config on the copy.
log 'Checking copied cluster for unsupported preload libraries and storage methods'
preload=$(docker run --rm --network none --user "$RUN_UID:$RUN_GID" --cap-drop ALL --security-opt no-new-privileges --read-only --mount "type=bind,source=$RUN_DIR/source/$SOURCE_MAJOR/docker,target=/check,readonly" --entrypoint postgres "postgres:$SOURCE_MAJOR" -D /check -C shared_preload_libraries)
[[ -z $preload ]] || fail 'Nonempty shared_preload_libraries: custom server/TDE migration is unsupported. See docs/encryption.md.'
log "Starting isolated containers: ${services[*]}"
started=1
"${DC[@]}" up -d "${services[@]}"
# Migration uses destination-version client tools; backup-only uses source tools.
CLIENT_SERVICE=target
if ((BACKUP_ONLY)); then CLIENT_SERVICE=source; fi
client() {
  local secret=$1; shift
  "${DC[@]}" exec -T "$CLIENT_SERVICE" sh -ec 'secret=$1; shift; export PGPASSWORD="$(cat "/run/secrets/$secret")"; export PGCONNECT_TIMEOUT=5 PGTZ=UTC; exec "$@"' sh "$secret" "$@"
}
source_sql() { client source_password psql -X -w -h source -U "$SOURCE_USER" -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
target_sql() { client source_password psql -X -w -h 127.0.0.1 -U "$SOURCE_USER" -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
bootstrap_sql() { client bootstrap_password psql -X -w -h 127.0.0.1 -U "$BOOTSTRAP_ROLE" -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
wait_sql() {
  local deadline=$((SECONDS + TIMEOUT))
  until "$@" -c 'SELECT 1' > /dev/null 2> "$RUN_DIR/readiness.log"; do
    if ((SECONDS >= deadline)); then cat "$RUN_DIR/readiness.log" >&2; "${DC[@]}" logs --tail=30 >&2 || true; fail 'Database readiness/authentication timed out.'; fi
    printf '.' >&2; sleep 2
  done
}
log "Waiting for source (up to ${TIMEOUT}s)"; wait_sql source_sql; printf "\n" >&2
if ((!BACKUP_ONLY)); then log "Waiting for target (up to ${TIMEOUT}s)"; wait_sql bootstrap_sql; printf "\n" >&2; fi
[[ $(source_sql -c 'SHOW server_version_num') -ge $((SOURCE_MAJOR*10000)) && $(source_sql -c 'SHOW server_version_num') -lt $(((SOURCE_MAJOR+1)*10000)) ]] || fail 'Source server version mismatch.'
if ((!BACKUP_ONLY)); then [[ $(bootstrap_sql -c 'SHOW server_version_num') -ge $((TARGET_MAJOR*10000)) && $(bootstrap_sql -c 'SHOW server_version_num') -lt $(((TARGET_MAJOR+1)*10000)) ]] || fail 'Target server version mismatch.'; fi
[[ $(source_sql -c 'SELECT rolsuper FROM pg_roles WHERE rolname=current_user') == t ]] || fail 'Source user must be a PostgreSQL superuser.'
[[ $(source_sql -c "SELECT count(*) FROM pg_roles WHERE rolname='$BOOTSTRAP_ROLE'") == 0 ]] || fail 'Temporary role collision.'
[[ $(source_sql -c "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global')") == 0 ]] || fail 'Custom tablespaces are unsupported.'
[[ $(source_sql -c 'SELECT count(*) FROM pg_replication_slots') == 0 ]] || fail 'Replication slots require a separate migration plan.'
[[ $(source_sql -c 'SELECT count(*) FROM pg_subscription') == 0 ]] || fail 'Subscriptions require a separate migration plan.'
[[ $(source_sql -c 'SELECT count(*) FROM pg_prepared_xacts') == 0 ]] || fail 'Prepared transactions must be resolved before migration.'
[[ $(source_sql -c "SELECT count(*) FROM pg_database WHERE NOT datallowconn AND datname <> 'template0'") == 0 ]] || fail 'Non-connectable user databases would not be dumped.'
client source_password psql -X -w -h source -U "$SOURCE_USER" -d "$SOURCE_DB" -v ON_ERROR_STOP=1 -At -c 'SELECT 1' >/dev/null
# Inspect each connectable database before dumping. Permit built-in PL/pgSQL
# and pgcrypto only. Reject unknown table access methods rather than risk a
# transparent-encryption downgrade. This is an allowlist, not a TDE detector.
log 'Checking extensions and table access methods in every connectable database'
source_sql -0 -c 'SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname' > "$RUN_DIR/database-names.bin"
while IFS= read -r -d '' db; do
  # Connection strings are not accepted as database names in this tool.
  [[ $db =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail "Unsupported database name: $db"
  log "Checking database: $db"
  extensions=$(client source_password psql -X -w -h source -U "$SOURCE_USER" -d "$db" -v ON_ERROR_STOP=1 -At -c "SELECT extname FROM pg_extension WHERE extname NOT IN ('plpgsql','pgcrypto') ORDER BY extname" </dev/null)
  [[ -z $extensions ]] || fail "Unsupported extensions in $db: $extensions. See docs/encryption.md."
  methods=$(client source_password psql -X -w -h source -U "$SOURCE_USER" -d "$db" -v ON_ERROR_STOP=1 -At -c "SELECT amname FROM pg_am WHERE amtype='t' AND amname <> 'heap'" </dev/null)
  [[ -z $methods ]] || fail "Unsupported table access methods in $db: $methods. TDE requires a vendor-specific migration."
done < "$RUN_DIR/database-names.bin"
log 'Extension and access-method checks passed (not a certification of physical encryption).'
# Stable logical inventories exclude version-specific built-in roles.
# These checks complement, but do not replace, application-level validation.
DB_QUERY="SELECT json_build_array(datname,pg_get_userbyid(datdba),pg_encoding_to_char(encoding),datistemplate,datallowconn) FROM pg_database WHERE datname <> 'template0' ORDER BY datname COLLATE \"C\";"
ROLE_QUERY="SELECT json_build_array(rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit) FROM pg_roles WHERE rolname !~ '^pg_' AND rolname <> '$BOOTSTRAP_ROLE' ORDER BY rolname COLLATE \"C\";"
source_sql -c "$DB_QUERY" > "$RUN_DIR/source-databases.jsonl"
source_sql -c "$ROLE_QUERY" > "$RUN_DIR/source-roles.jsonl"
log 'Creating cluster-wide SQL dump (includes roles and password hashes)'
log "Backup destination: $RUN_DIR/$BACKUP_NAME"
dump_cluster() {
  client source_password pg_dumpall --verbose -h source -U "$SOURCE_USER" -l postgres -w --clean --if-exists --quote-all-identifiers 2> >(tee "$RUN_DIR/dump.log" >&2)
}
if ((ENCRYPT)); then
  log 'Streaming SQL directly into age; no plaintext SQL dump file'
  dump_cluster | "${AGE_RUN[@]}" "${AGE_ENCRYPT[@]}" > "$RUN_DIR/$BACKUP_NAME.part"
else
  dump_cluster > "$RUN_DIR/$BACKUP_NAME.part"
fi
[[ -s $RUN_DIR/$BACKUP_NAME.part ]] || fail 'Empty dump.'
mv -- "$RUN_DIR/$BACKUP_NAME.part" "$RUN_DIR/$BACKUP_NAME"
(cd "$RUN_DIR" && sha256sum "$BACKUP_NAME" > "$BACKUP_NAME.sha256")
log "Backup completed: $(stat -c %s -- "$RUN_DIR/$BACKUP_NAME") bytes; SHA-256 recorded."
if ((BACKUP_ONLY)); then
  if ((ENCRYPT)) && [[ -n $IDENTITY_FILE ]]; then
    "${AGE_RUN[@]}" "${AGE_DECRYPT[@]}" < "$RUN_DIR/$BACKUP_NAME" > /dev/null
  fi
  log 'Backup-only: verifying checksum and stopping temporary source without publishing a target'
  (cd "$RUN_DIR" && sha256sum -c "$BACKUP_NAME.sha256")
  "${DC[@]}" logs --no-color > "$RUN_DIR/container.log" 2>&1
  "${DC[@]}" down --timeout 120 2>&1 | tee "$RUN_DIR/cleanup.log"
  started=0
  printf 'Backup verified: %s\nSource retained: %s\n' "$RUN_DIR/$BACKUP_NAME" "$SOURCE_DATA" > "$RUN_DIR/BACKUP.txt"
  printf 'BACKUP COMPLETE: %s\nNo target published. Keep the original image tag and restart the original application when ready.\n' "$RUN_DIR/$BACKUP_NAME"
  if ((ENCRYPT)); then log 'Retain the private decryption identity separately; test recovery before relying on the backup.'; fi
  exit 0
fi
log 'Restoring into the new cluster; abort on first SQL error'
# psql must stop on the first SQL error; pipefail propagates decrypt/restore
# errors even when tee writes diagnostics successfully.
restore_cluster() {
  client bootstrap_password psql -X -w -h 127.0.0.1 -U "$BOOTSTRAP_ROLE" -d postgres -v ON_ERROR_STOP=1 -f - 2>&1 | tee "$RUN_DIR/restore.log"
}
if ((ENCRYPT)); then
  "${AGE_RUN[@]}" "${AGE_DECRYPT[@]}" < "$RUN_DIR/$BACKUP_NAME" | restore_cluster
else
  restore_cluster < "$RUN_DIR/$BACKUP_NAME"
fi
log 'Verifying restored credentials, database inventory and role inventory'
# Confirm the restored extension versions exist and match extension names.
# Extension versions may legitimately differ across PostgreSQL releases.
while IFS= read -r -d '' db; do
  log "Comparing extension inventory: $db"
  query='SELECT extname FROM pg_extension ORDER BY extname COLLATE "C"'
  src_ext=$(client source_password psql -X -w -h source -U "$SOURCE_USER" -d "$db" -v ON_ERROR_STOP=1 -At -c "$query" </dev/null)
  dst_ext=$(client source_password psql -X -w -h 127.0.0.1 -U "$SOURCE_USER" -d "$db" -v ON_ERROR_STOP=1 -At -c "$query" </dev/null)
  [[ $src_ext == "$dst_ext" ]] || fail "Extension inventory mismatch in $db."
done < "$RUN_DIR/database-names.bin"
target_sql -c "$DB_QUERY" > "$RUN_DIR/target-databases.jsonl"
target_sql -c "$ROLE_QUERY" > "$RUN_DIR/target-roles.jsonl"
diff -u "$RUN_DIR/source-databases.jsonl" "$RUN_DIR/target-databases.jsonl" | tee "$RUN_DIR/databases.diff" || fail 'Database inventory differs; inspect databases.diff.'
diff -u "$RUN_DIR/source-roles.jsonl" "$RUN_DIR/target-roles.jsonl" | tee "$RUN_DIR/roles.diff" || fail 'Role inventory differs; inspect roles.diff.'
client source_password psql -X -w -h 127.0.0.1 -U "$SOURCE_USER" -d "$SOURCE_DB" -v ON_ERROR_STOP=1 -At -c 'SELECT 1' >/dev/null
log 'Checking role credentials and role memberships (private checksums only)'
HASH_QUERY="SELECT json_build_array(rolname,rolpassword,rolvaliduntil AT TIME ZONE 'UTC') FROM pg_authid WHERE rolname !~ '^pg_' AND rolname <> '$BOOTSTRAP_ROLE' ORDER BY rolname COLLATE \"C\";"
MEMBER_QUERY="SELECT json_build_array(r.rolname,m.rolname,a.admin_option,a.inherit_option,a.set_option) FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member WHERE r.rolname <> '$BOOTSTRAP_ROLE' AND m.rolname <> '$BOOTSTRAP_ROLE' AND NOT (r.rolname ~ '^pg_' AND m.rolname ~ '^pg_') ORDER BY r.rolname COLLATE \"C\",m.rolname COLLATE \"C\",a.admin_option,a.inherit_option,a.set_option;"
for query in "$HASH_QUERY" "$MEMBER_QUERY"; do
  source_hash=$(source_sql -c "$query" | sha256sum)
  target_hash=$(target_sql -c "$query" | sha256sum)
  [[ $source_hash == "$target_hash" ]] || fail 'Role password/validity or membership verification failed.'
done
log 'Updating optimizer statistics and disabling temporary bootstrap login'
client source_password vacuumdb -h 127.0.0.1 -U "$SOURCE_USER" -w --all --analyze-in-stages 2>&1 | tee "$RUN_DIR/analyze.log"
target_sql -c "ALTER ROLE \"$BOOTSTRAP_ROLE\" NOLOGIN PASSWORD NULL;" >/dev/null
[[ $(target_sql -c "SELECT rolcanlogin FROM pg_roles WHERE rolname='$BOOTSTRAP_ROLE'") == f ]] || fail 'Bootstrap login was not disabled.'
log 'Stopping temporary servers cleanly'
"${DC[@]}" logs --no-color > "$RUN_DIR/container.log" 2>&1
"${DC[@]}" down --timeout 120 2>&1 | tee "$RUN_DIR/cleanup.log"
started=0
[[ $(cat "$RUN_DIR/target/$TARGET_MAJOR/docker/PG_VERSION") == "$TARGET_MAJOR" ]] || fail 'Unexpected target PG_VERSION.'
[[ ! -e $RUN_DIR/target/$TARGET_MAJOR/docker/postmaster.pid ]] || fail 'Target did not shut down cleanly.'
[[ $(stat -c '%u:%g' "$RUN_DIR/target/$TARGET_MAJOR/docker") == "$RUN_UID:$RUN_GID" ]] || fail 'Unexpected target data ownership.'
control_state "$RUN_DIR/target/$TARGET_MAJOR/docker" "$TARGET_MAJOR" | tee "$RUN_DIR/target-control.log"
grep -Eq '^Database cluster state:[[:space:]]+shut down$' "$RUN_DIR/target-control.log" || fail 'Target was not cleanly shut down.'
log 'Checking offline status again before publishing'
check_offline
[[ ! -e $FINAL_DIR && ! -L $FINAL_DIR ]] || fail 'Target directory appeared during migration; refusing to overwrite.'
# Restore production ownership on the verified staged target, not on the original.
# Keep the enclosing major directory owned by the launcher so an unprivileged
# same-filesystem rename can update its parent. Only PGDATA needs the database
# identity. Permit traversal by the database UID without exposing PGDATA.
TARGET_PARENT_MODE=700
if [[ $DATA_UID != "$RUN_UID" ]]; then TARGET_PARENT_MODE=711; fi
if [[ $PARENT_MODE == 755 ]]; then TARGET_PARENT_MODE=755; fi
log "Preparing target PGDATA ownership $DATA_UID:$DATA_GID; major directory $RUN_UID:$RUN_GID mode $TARGET_PARENT_MODE"
"${HELPER[@]}" --cap-add CHOWN --cap-add FOWNER \
  --mount "type=bind,source=$RUN_DIR/target/$TARGET_MAJOR,target=/staged" \
  --entrypoint sh alpine:latest -eu -c '
    chown -R "$1:$2" /staged/docker
    chmod "$3" /staged/docker
    # initdb was given --allow-group-access for a source mode of 750; do
    # not blanket-widen the generated individual file permissions.
    chown "$4:$5" /staged
    chmod "$6" /staged
    [ "$(stat -c "%u:%g:%a" /staged/docker)" = "$1:$2:$3" ]
    [ "$(stat -c "%u:%g:%a" /staged)" = "$4:$5:$6" ]
  ' sh "$DATA_UID" "$DATA_GID" "$DATA_MODE" "$RUN_UID" "$RUN_GID" "$TARGET_PARENT_MODE"
(cd "$RUN_DIR" && sha256sum -c "$BACKUP_NAME.sha256")
cat > "$RUN_DIR/READY.txt" <<REPORT
Logical migration verified: PostgreSQL $SOURCE_MAJOR -> $TARGET_MAJOR
Original data: $SOURCE_PATH/$SOURCE_MAJOR (not modified)
New directory: $FINAL_DIR
Published PGDATA UID:GID and mode: $DATA_UID:$DATA_GID $DATA_MODE
Published major directory UID:GID and mode: $RUN_UID:$RUN_GID $TARGET_PARENT_MODE
SQL backup: $RUN_DIR/$BACKUP_NAME
Temporary bootstrap role: $BOOTSTRAP_ROLE (NOLOGIN, password removed)
Checks: dump/restore exit status, version, database and role inventory, original credentials, role password/validity and memberships, statistics, clean shutdown and ownership.
REPORT
# Commit point: same-filesystem atomic rename, no overwrite. GNU mv -n can
# return success when skipping, so also check that staging actually moved.
log "Publishing $FINAL_DIR (leaving $SOURCE_PATH/$SOURCE_MAJOR untouched)"
sync -f "$RUN_DIR/target"
mv "${MV_OPTS[@]}" -- "$RUN_DIR/target/$TARGET_MAJOR" "$FINAL_DIR"
[[ ! -e $RUN_DIR/target/$TARGET_MAJOR && -d $FINAL_DIR ]] || fail 'Publication was skipped; target may already exist.'
published=1
printf '\nSUCCESS: PostgreSQL %s -> %s\n' "$SOURCE_MAJOR" "$TARGET_MAJOR"
cat "$RUN_DIR/READY.txt"
printf '\nNEXT STEPS (manual):\n1. Change ONLY the original application Compose image to postgres:%s.\n2. Run docker compose up -d using the original environment/secrets (or redeploy in Dockhand).\n3. Verify database health and application data.\n4. Keep %s until satisfied; delete it manually only after verification.\nRollback: stop application, select postgres:%s and redeploy. Writes to the new cluster will not be present in the old one.\n' "$TARGET_MAJOR" "$SOURCE_PATH/$SOURCE_MAJOR" "$SOURCE_MAJOR"
