#!/bin/bash
# restore-postgres.sh: a pg_restore that fails ONLY on ownership/privilege statements for roles that
# do not exist in the target counts as restored (with a WARNING). Every other failure still ends
# the job with "ERROR: pg_restore failed" and exit status 5.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

new_env() {
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  SCRIPTS="$WORK/scripts"
  mkdir -p "$STUBS"
  cp -R "$ROOT/scripts" "$SCRIPTS"
  chmod +x "$SCRIPTS"/*.sh
  rm -f /tmp/download.* /tmp/decrypted.* /tmp/restore.* /tmp/pg_restore.err*
  printf 'dump' >"$WORK/fixture"
  cat >"$STUBS/mc" <<'STUB'
#!/bin/bash
case "$1" in
  cp) cp "$MC_FIXTURE" "$3"; exit 0 ;;
esac
exit 0
STUB
  # pg_restore: print $PG_STDERR to stderr and exit $PG_RC.
  cat >"$STUBS/pg_restore" <<'STUB'
#!/bin/bash
printf '%b' "${PG_STDERR:-}" >&2
exit "${PG_RC:-0}"
STUB
  chmod +x "$STUBS"/*
}

run_script() {
  OUT=$(env PATH="$STUBS:$PATH" MC_FIXTURE="$WORK/fixture" \
    DB_HOST=10.9.9.9 DB_PORT=1234 DB_USER=dbuser DB_PASSWORD=pw DB_NAME=app \
    S3_ENDPOINT=http://127.0.0.1:9 S3_ACCESS_KEY=ak S3_SECRET_KEY=sk S3_BUCKET=b S3_KEY=k \
    "$@" bash "$SCRIPTS/restore-postgres.sh" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}

rc_is() { [ "$RC" -eq "$1" ]; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
lacks() { ! printf '%s\n' "$OUT" | grep -qF -- "$1"; }

ROLE_ERR='pg_restore: error: could not execute query: ERROR:  role "app_role" does not exist\nCommand was: ALTER TABLE public.t OWNER TO app_role;\n'
GRANT_ERR='pg_restore: error: could not execute query: ERROR:  role "app_role" does not exist\nCommand was: GRANT ALL ON TABLE public.t TO app_role;\n'
DEFPRIV_ERR='pg_restore: error: could not execute query: ERROR:  role "app_role" does not exist\nCommand was: ALTER DEFAULT PRIVILEGES FOR ROLE app_role IN SCHEMA public GRANT ALL ON TABLES TO app_role;\n'
OTHER_ERR='pg_restore: error: could not execute query: ERROR:  relation "public.t" already exists\nCommand was: CREATE TABLE public.t (id integer);\n'
SUMMARY='pg_restore: warning: errors ignored on restore: 3\n'

echo "clean restore"
new_env
run_script PG_RC=0
expect "exit 0" rc_is 0
expect "success line" has "PostgreSQL restore completed successfully"
expect "no warning" lacks "WARNING:"

echo "only missing-role ownership and privilege errors"
new_env
run_script PG_RC=1 PG_STDERR="${ROLE_ERR}${GRANT_ERR}${DEFPRIV_ERR}${SUMMARY}"
expect "exit 0" rc_is 0
expect "success line" has "PostgreSQL restore completed successfully"
expect "warning names the count" has "WARNING: 3 ownership/privilege statements were skipped"
expect "warning names the role" has "role(s) app_role do not exist"
expect "no failure line" lacks "ERROR: pg_restore failed"

echo "missing-role errors mixed with another error"
new_env
run_script PG_RC=1 PG_STDERR="${ROLE_ERR}${OTHER_ERR}${SUMMARY}"
expect "exit 5" rc_is 5
expect "ERROR: pg_restore failed" has "ERROR: pg_restore failed"
expect "no success line" lacks "restore completed successfully"

echo "missing role on a statement that is not ownership or privileges"
new_env
run_script PG_RC=1 PG_STDERR='pg_restore: error: could not execute query: ERROR:  role "app_role" does not exist\nCommand was: CREATE TABLE public.t (owner name DEFAULT app_role::name);\n'
expect "exit 5" rc_is 5
expect "ERROR: pg_restore failed" has "ERROR: pg_restore failed"

echo "non-zero exit with no pg_restore error lines (for example a connection failure)"
new_env
run_script PG_RC=1 PG_STDERR='pg_restore: error: connection to server at "10.9.9.9", port 1234 failed\n'
expect "exit 5" rc_is 5
expect "ERROR: pg_restore failed" has "ERROR: pg_restore failed"

echo "exit status other than 1"
new_env
run_script PG_RC=2 PG_STDERR="${ROLE_ERR}"
expect "exit 5" rc_is 5

echo "quoted role names and a role error mixed with a COPY failure"
new_env
run_script PG_RC=1 PG_STDERR='pg_restore: error: could not execute query: ERROR:  role "Weird Role-1" does not exist\nCommand was: ALTER TABLE public.t OWNER TO "Weird Role-1";\n\npg_restore: error: could not execute query: ERROR:  role "app_role" does not exist\nCommand was: GRANT ALL ON TABLE public.t TO app_role;\n\npg_restore: warning: errors ignored on restore: 2\n'
expect "exit 0" rc_is 0
expect "both roles named, deduplicated and sorted" has "role(s) Weird Role-1,app_role do not exist"
new_env
run_script PG_RC=1 PG_STDERR="${ROLE_ERR}"'pg_restore: error: COPY failed for table "t": ERROR:  invalid input syntax for type integer: "x"\n'"${SUMMARY}"
expect "exit 5" rc_is 5
expect "ERROR: pg_restore failed" has "ERROR: pg_restore failed"

echo "no temp file is left behind"
new_env
run_script PG_RC=1 PG_STDERR="${ROLE_ERR}${OTHER_ERR}${SUMMARY}"
expect "failure path removes the stderr file" bash -c '! ls /tmp/pg_restore.err.* >/dev/null 2>&1'
new_env
run_script PG_RC=1 PG_STDERR="${ROLE_ERR}${SUMMARY}"
expect "success path removes the stderr file" bash -c '! ls /tmp/pg_restore.err.* >/dev/null 2>&1'

echo "$PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
