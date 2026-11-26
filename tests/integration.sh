#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
set -Eeuo pipefail
umask 077
source_major=${1:?source major}; target_major=${2:?target major}; mode=${3:-plain}
[[ $mode == plain || $mode == encrypted ]] || exit 2
ownership=${4:-host}
[[ $ownership == host || $ownership =~ ^[1-9][0-9]*:[0-9]+$ ]] || exit 2
repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d); name="pg-upgrade-ci-$$"; uid=$(id -u); gid=$(id -g)
db_uid=$uid; db_gid=$gid
if [[ $ownership != host ]]; then db_uid=${ownership%:*}; db_gid=${ownership#*:}; fi
# Fixture helpers deliberately access the protected cluster via Docker, not sudo.
FIXTURE=(docker run --rm --network none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE --cap-add CHOWN --cap-add FOWNER --security-opt no-new-privileges --read-only)
fixture() { "${FIXTURE[@]}" --mount "type=bind,source=$root/db,target=/db" --entrypoint bash "postgres:$source_major" -euo pipefail -c "$@"; }
fixture_ro() { "${FIXTURE[@]}" --mount "type=bind,source=$root/db,target=/db,readonly,bind-recursive=readonly" --entrypoint bash "postgres:$source_major" -euo pipefail -c "$@"; }
cleanup() { rc=$?; trap - EXIT; docker logs "$name" >&2 2>/dev/null || true; docker rm -f "$name" >/dev/null 2>&1 || true; if ((rc)); then echo "Test failed; diagnostics in $root" >&2; find "$root" -path "$root/db" -prune -o \( -name 'restore.log' -o -name 'readiness.log' \) -print | while read -r f; do tail -n 40 "$f"; done; else fixture 'rm -rf /db/*' && rm -rf "$root" || rc=1; fi; exit "$rc"; }
trap cleanup EXIT
mkdir -m 755 "$root/db"; printf '%s' 'ci-test-password-123' > "$root/password"
start() {
  # For a fresh fixture, emulate the official root entrypoint's directory setup.
  if [[ ! -e $root/db/$1 ]]; then
    fixture 'mkdir -p "/db/$1/docker"; chown "$2:$3" "/db/$1/docker"; chmod 755 "/db/$1"; chmod 700 "/db/$1/docker"' sh "$1" "$db_uid" "$db_gid"
  fi
  docker run -d --name "$name" --network none --user "$db_uid:$db_gid" \
    --mount "type=bind,source=$root/db,target=/var/lib/postgresql" \
    -e POSTGRES_USER=pgadmin -e POSTGRES_DB=appdb \
    -e POSTGRES_PASSWORD=ci-test-password-123 \
    -e 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256' \
    -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
    "postgres:$1" >/dev/null
  for ((i=0;i<90;i++)); do
    if sql appdb -Atc 'SELECT 1' >/dev/null 2>&1; then return; fi
    sleep 2
  done
  echo 'Database startup timed out' >&2; return 1
}
sql() { local db=$1; shift; docker exec -i -e PGPASSWORD=ci-test-password-123 "$name" psql -X -w -h 127.0.0.1 -U pgadmin -d "$db" -v ON_ERROR_STOP=1 "$@"; }
stop() { docker stop -t 60 "$name" >/dev/null; docker rm "$name" >/dev/null; }
fingerprint() {
  fixture_ro 'cd "/db/$1"; find . -printf "%p %U:%G %m %y\n" | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum' sh "$source_major"
}
start "$source_major"
sql appdb <<'SQL'
CREATE ROLE appuser LOGIN PASSWORD 'ci-app-password';
CREATE TABLE sample(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, value text NOT NULL);
INSERT INTO sample(value) VALUES ('alpha'), ('beta'), ('Berlin');
GRANT SELECT ON sample TO appuser;
-- Store encrypted values exactly as a real pgcrypto application would.
CREATE EXTENSION pgcrypto;
CREATE TABLE encrypted_sample(id int PRIMARY KEY, ciphertext bytea NOT NULL);
INSERT INTO encrypted_sample VALUES (1, pgp_sym_encrypt('private test value', 'fixture-key'));
CREATE DATABASE extra;
SQL
sql extra -c 'CREATE TABLE extra_data AS SELECT 42 AS answer;'
# The random ciphertext itself must survive, not merely its decrypted value.
ciphertext=$(sql appdb -Atc "SELECT encode(ciphertext,'hex') FROM encrypted_sample")
stop
# Simulate a vendor/custom preload requirement on the stopped fixture.
# The tool must refuse to bypass it and must not modify even this source.
# Confirm the fixture actually reproduces the reported permission mismatch.
if [[ $db_uid != "$uid" ]]; then
  test ! -r "$root/db/$source_major/docker/PG_VERSION"
fi
fixture_ro 'cat "/db/$1/docker/postgresql.conf"' sh "$source_major" > "$root/original-postgresql.conf"
printf "\nshared_preload_libraries = 'unsupported_tde_fixture'\n" | "${FIXTURE[@]}" -i --mount "type=bind,source=$root/db,target=/db" --entrypoint sh "postgres:$source_major" -eu -c 'cat >> "/db/$1/docker/postgresql.conf"' sh "$source_major"
fingerprint > "$root/preload.sha"
if bash "$repo/migrate.sh" --source "$root/db" --source-major "$source_major" --user pgadmin --password-file "$root/password" --backup-only; then
  echo 'Unsupported preload unexpectedly accepted' >&2; exit 1
fi
fingerprint | diff - "$root/preload.sha"
test ! -e "$root/db/$target_major"
"${FIXTURE[@]}" -i --mount "type=bind,source=$root/db,target=/db" --entrypoint sh "postgres:$source_major" -eu -c 'cat > "/db/$1/docker/postgresql.conf"' sh "$source_major" < "$root/original-postgresql.conf"
fingerprint > "$root/original.sha"
args=(--source "$root/db" --source-major "$source_major" --target-major "$target_major" --user pgadmin --database appdb --timeout 120)
printf '%s' wrong-password > "$root/wrong"
if bash "$repo/migrate.sh" "${args[@]}" --password-file "$root/wrong" --timeout 8; then echo 'Wrong password unexpectedly succeeded' >&2; exit 1; fi
test ! -e "$root/db/$target_major"
fingerprint | diff - "$root/original.sha"
if [[ $mode == encrypted ]]; then
  docker build --pull -t pg-upgrade-age:latest -f "$repo/docker/Dockerfile.age" "$repo/docker"
  docker run --rm --network none --entrypoint age-keygen pg-upgrade-age:latest > "$root/identity"
  docker run --rm --network none --entrypoint age-keygen pg-upgrade-age:latest > "$root/wrong-identity"
  recipient=$(docker run --rm -i --network none --entrypoint age-keygen pg-upgrade-age:latest -y < "$root/identity")
  printf '%s\n' "$recipient" > "$root/recipients"
  if bash "$repo/migrate.sh" "${args[@]}" --password-file "$root/password" --encrypt-backup --identity-file "$root/wrong-identity" --encryption-key-file "$root/recipients"; then echo 'Mismatched identity unexpectedly succeeded' >&2; exit 1; fi
  test ! -e "$root/db/$target_major"
  fingerprint | diff - "$root/original.sha"
  bash "$repo/migrate.sh" --source "$root/db" --user pgadmin --database appdb --password-file "$root/password" --encrypt-backup --encryption-recipient "$recipient" --backup-only
  test ! -e "$root/db/$target_major"
  fingerprint | diff - "$root/original.sha"
  bash "$repo/migrate.sh" "${args[@]}" --password-file "$root/password" --encrypt-backup --identity-file "$root/identity" --encryption-key-file "$root/recipients"
  test -z "$(find "$root" -path "$root/db" -prune -o \( -name cluster.sql -o -name cluster.sql.part -o -name cluster.sql.age.part \) -print)"
  count=0
  while IFS= read -r -d '' backup; do
    (cd "$(dirname "$backup")" && sha256sum -c cluster.sql.age.sha256)
    docker run --rm -i --network none --user "$uid:$gid" --mount "type=bind,source=$root/identity,target=/identity,readonly" pg-upgrade-age:latest -d -i /identity < "$backup" | grep -F 'PostgreSQL database cluster dump complete' >/dev/null
    if docker run --rm -i --network none --user "$uid:$gid" --mount "type=bind,source=$root/wrong-identity,target=/identity,readonly" pg-upgrade-age:latest -d -i /identity < "$backup" >/dev/null 2>&1; then echo 'Wrong key decrypted backup' >&2; exit 1; fi
    count=$((count+1))
  done < <(find "$root" -path "$root/db" -prune -o -name cluster.sql.age -print0)
  test "$count" = 2
else
  bash "$repo/migrate.sh" --source "$root/db" --user pgadmin --database appdb --password-file "$root/password" --backup-only
  test ! -e "$root/db/$target_major"
  fingerprint | diff - "$root/original.sha"
  bash "$repo/migrate.sh" "${args[@]}" --password-file "$root/password"
fi
fingerprint | diff - "$root/original.sha"
test "$(fixture_ro 'cat "/db/$1/docker/PG_VERSION"' sh "$target_major")" = "$target_major"
test "$(fixture_ro 'stat -c "%u:%g:%a" "/db/$1/docker"' sh "$target_major")" = "$db_uid:$db_gid:700"
if [[ $db_uid != "$uid" ]]; then test ! -r "$root/db/$target_major/docker/PG_VERSION"; fi
if bash "$repo/migrate.sh" "${args[@]}" --password-file "$root/password"; then echo 'Existing target unexpectedly overwritten' >&2; exit 1; fi
start "$target_major"
test "$(sql appdb -Atc "SELECT encode(ciphertext,'hex') FROM encrypted_sample")" = "$ciphertext"
test "$(sql appdb -Atc "SELECT pgp_sym_decrypt(ciphertext,'fixture-key') FROM encrypted_sample")" = 'private test value'
test "$(sql appdb -Atc 'SELECT string_agg(value, '"'"','"'"' ORDER BY id) FROM sample')" = 'alpha,beta,Berlin'
test "$(sql extra -Atc 'SELECT answer FROM extra_data')" = 42
test "$(docker exec -e PGPASSWORD=ci-app-password "$name" psql -X -w -h 127.0.0.1 -U appuser -d appdb -Atc 'SELECT count(*) FROM sample')" = 3
test "$(sql appdb -Atc "INSERT INTO sample(value) VALUES ('new') RETURNING id" | head -n1)" = 4
stop
# Start the old image while both directories exist; confirm target writes did not leak.
start "$source_major"
test "$(sql appdb -Atc 'SELECT count(*) FROM sample')" = 3
stop
echo "PASS ($mode, $ownership): $source_major -> $target_major, failure safety, preserved bytes, roles, grants, sequences and rollback"
