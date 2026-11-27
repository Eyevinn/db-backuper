#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=error-trap.sh
. "${SCRIPT_DIR}/error-trap.sh"
DUMP_FILE="/tmp/restore.dump"

echo "Starting PostgreSQL restore: ${DB_HOST}:${DB_PORT}/${DB_NAME:-<all>}"

RESTORE_STEP="download"
"${SCRIPT_DIR}/s3-download.sh" "${S3_BUCKET}" "${S3_KEY}" "/tmp/download.dump" || { echo "ERROR: S3 download failed" >&2; exit 3; }

if [ -n "${ENCRYPTION_KEY:-}" ]; then
  RESTORE_STEP="decrypt"
  "${SCRIPT_DIR}/decrypt.sh" "/tmp/download.dump" "${DUMP_FILE}" || { echo "ERROR: Decryption failed" >&2; exit 4; }
  rm -f /tmp/download.dump
else
  mv /tmp/download.dump "${DUMP_FILE}"
fi

RESTORE_STEP="restore"
export PGPASSWORD="${DB_PASSWORD}"

PG_RESTORE_ERRORS="$(mktemp /tmp/pg_restore.err.XXXXXX)"
trap 'rm -f "${PG_RESTORE_ERRORS}"' EXIT

# pg_restore keeps going after a failed statement and exits non-zero at the end. Capture stderr so
# the one harmless case below can be told apart from a real failure. `if` keeps the ERR trap quiet.
if pg_restore \
  -h "${DB_HOST}" \
  -p "${DB_PORT}" \
  -U "${DB_USER}" \
  ${DB_NAME:+-d "${DB_NAME}"} \
  --clean \
  --if-exists \
  "${DUMP_FILE}" 2>"${PG_RESTORE_ERRORS}"; then
  PG_RESTORE_RC=0
else
  PG_RESTORE_RC=$?
fi
cat "${PG_RESTORE_ERRORS}" >&2

if [ "${PG_RESTORE_RC}" -ne 0 ]; then
  # The dump names the roles that own the objects. A target without those roles (a new instance, or
  # a verification instance) rejects only the ownership and privilege statements; the data loads.
  # Treat the run as restored only when EVERY error is "role ... does not exist" on such a
  # statement. Any other error still fails the job.
  ERROR_COUNT=$(grep -c '^pg_restore: error:' "${PG_RESTORE_ERRORS}" || true)
  ROLE_ERROR_COUNT=$(grep -c '^pg_restore: error: could not execute query: ERROR:  role ".*" does not exist$' "${PG_RESTORE_ERRORS}" || true)
  COMMAND_COUNT=$(grep -c '^Command was: ' "${PG_RESTORE_ERRORS}" || true)
  OWNERSHIP_COMMAND_COUNT=$(grep -c -E '^Command was: (ALTER .* OWNER TO |GRANT |REVOKE |ALTER DEFAULT PRIVILEGES)' "${PG_RESTORE_ERRORS}" || true)
  if [ "${PG_RESTORE_RC}" -eq 1 ] && [ "${ERROR_COUNT}" -gt 0 ] \
    && [ "${ERROR_COUNT}" -eq "${ROLE_ERROR_COUNT}" ] \
    && [ "${ERROR_COUNT}" -eq "${COMMAND_COUNT}" ] \
    && [ "${ERROR_COUNT}" -eq "${OWNERSHIP_COMMAND_COUNT}" ]; then
    MISSING_ROLES=$(sed -n 's/^pg_restore: error: could not execute query: ERROR:  role "\(.*\)" does not exist$/\1/p' "${PG_RESTORE_ERRORS}" | sort -u | paste -sd, -)
    echo "WARNING: ${ERROR_COUNT} ownership/privilege statements were skipped because the role(s) ${MISSING_ROLES} do not exist in the target. The data was restored; object owners and grants for those roles were not applied." >&2
  else
    echo "ERROR: pg_restore failed" >&2
    exit 5
  fi
fi
rm -f "${DUMP_FILE}"
echo "PostgreSQL restore completed successfully"
