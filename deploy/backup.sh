#!/usr/bin/env bash
# Postgres backup → backups/eden-YYYYmmdd-HHMMSS.sql.gz, keeping the last 14.
# Run from the deploy dir; schedule via cron (e.g. daily). A backup on the same
# disk dies with it — ship these off-box (R2/scp) for real durability.
set -euo pipefail
cd -- "$(dirname -- "$0")"
umask 077   # dumps contain everything — keep them owner-only

mkdir -p backups
stamp="$(date +%Y%m%d-%H%M%S)"
out="backups/eden-${stamp}.sql.gz"

# Read the DB credentials from the db CONTAINER's own env (POSTGRES_USER/DB),
# not by shell-sourcing .env — a strong password with shell metacharacters
# ($, spaces, backticks) would otherwise corrupt the command or the credentials.
#
# Dump to a temp file and rename only on success, so a failed pg_dump can't leave
# a truncated/empty file that retention (and a future restore) mistakes for a
# good backup.
tmp="${out}.part"
if docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip >"${tmp}"; then
  mv -- "${tmp}" "${out}"
else
  rm -f -- "${tmp}"
  echo "backup FAILED (pg_dump errored); no file written" >&2
  exit 1
fi

# Retain the 14 most recent (robust on the first run / empty dir).
find backups -name 'eden-*.sql.gz' -printf '%T@ %p\n' \
  | sort -rn | tail -n +15 | cut -d' ' -f2- | xargs -r rm --

echo "backup written: ${out}"
