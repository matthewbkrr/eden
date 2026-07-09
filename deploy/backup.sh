#!/usr/bin/env bash
# Postgres backup → backups/eden-YYYYmmdd-HHMMSS.sql.gz, keeping the last 14, then
# mirrored OFF-BOX to S3/Cloudflare R2 for real durability — a backup on the same disk
# dies with the disk. Off-box is OPT-IN: set EDEN_BACKUP_S3_* in .env (a DEDICATED
# bucket + key, isolated from the media EDEN_S3_* so a leaked media key can't reach the
# backups). Run from the deploy dir; schedule via cron (e.g. daily).
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

# Retain the 14 most recent locally (robust on the first run / empty dir).
find backups -name 'eden-*.sql.gz' -printf '%T@ %p\n' \
  | sort -rn | tail -n +15 | cut -d' ' -f2- | xargs -r rm --

echo "backup written: ${out}"

# ── Off-box mirror (opt-in) ──────────────────────────────────────────────────────────
# Read each S3/R2 setting from .env LITERALLY (grep + cut, never `source`) so a secret
# with $, spaces, or backticks is passed as-is, not evaluated.
env_val() { grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d '=' -f 2- ; }

bak_bucket="$(env_val EDEN_BACKUP_S3_BUCKET)"
if [ -z "${bak_bucket}" ]; then
  echo "off-box mirror SKIPPED — set EDEN_BACKUP_S3_* in .env for durable backups" >&2
  exit 0
fi

bak_region="$(env_val EDEN_BACKUP_S3_REGION)";   bak_region="${bak_region:-auto}"
bak_provider="$(env_val EDEN_BACKUP_S3_PROVIDER)"; bak_provider="${bak_provider:-Other}"

# rclone runs in a throwaway container — nothing is installed on the host, and the image
# is small (matters after the disk-full incident). The dumps are owner-only; mount read-only.
rclone_dest() {
  docker run --rm \
    -e RCLONE_CONFIG_DEST_TYPE=s3 \
    -e RCLONE_CONFIG_DEST_PROVIDER="${bak_provider}" \
    -e RCLONE_CONFIG_DEST_REGION="${bak_region}" \
    -e RCLONE_CONFIG_DEST_ENDPOINT="$(env_val EDEN_BACKUP_S3_ENDPOINT)" \
    -e RCLONE_CONFIG_DEST_ACCESS_KEY_ID="$(env_val EDEN_BACKUP_S3_ACCESS_KEY_ID)" \
    -e RCLONE_CONFIG_DEST_SECRET_ACCESS_KEY="$(env_val EDEN_BACKUP_S3_SECRET_ACCESS_KEY)" \
    -v "${PWD}/backups:/backups:ro" \
    rclone/rclone:latest "$@"
}

# Mirror the local backups dir to the bucket under an `eden-pg/` prefix: uploads the new
# dump and deletes the remote copy of whatever the keep-14 prune just removed, so the
# remote set equals the local one (the 14 newest) — retention handled by the same mirror.
if rclone_dest sync /backups "DEST:${bak_bucket}/eden-pg"; then
  echo "backup mirrored off-box: ${bak_bucket}/eden-pg (14 newest)"
else
  echo "WARNING: off-box mirror FAILED — the local backup is kept, but off-box durability is at risk" >&2
  exit 2
fi
