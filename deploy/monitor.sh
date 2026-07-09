#!/usr/bin/env bash
# Health + disk watch → Telegram alert. This project has NO email (RU deliverability
# from the overseas VPS is unreliable), so alerts go to Telegram instead. Run from the
# deploy dir via cron, e.g. every 10 min:
#   */10 * * * * /opt/eden/monitor.sh >> /opt/eden/monitor.log 2>&1
#
# Checks, in order (a failing one never aborts the rest — NO `set -e`):
#   1. disk %   ≥ EDEN_DISK_ALERT_PCT (default 80) on /var/lib/docker → alert
#   2. the app container's health (the compose healthcheck already curls /healthz) → alert
#   3. dead-man ping: when 1+2 are healthy, GET EDEN_HEALTHCHECK_URL. If the box dies
#      entirely, the pings stop and that external service alerts — the one failure this
#      on-box script cannot catch itself.
# Opt-in: without EDEN_ALERT_TELEGRAM_* it only logs to stderr (+ pings, if the URL is set).
set -uo pipefail
cd -- "$(dirname -- "$0")"

# Same literal .env reader as backup.sh: no `source` (a secret with $/spaces/backticks stays
# literal), strips surrounding quotes + a trailing CR, and never fails the run (|| true).
env_val() {
  grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d '=' -f 2- \
    | sed -e 's/\r$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true
}

tg_token="$(env_val EDEN_ALERT_TELEGRAM_TOKEN)"
tg_chat="$(env_val EDEN_ALERT_TELEGRAM_CHAT)"
disk_pct="$(env_val EDEN_DISK_ALERT_PCT)"; disk_pct="${disk_pct:-80}"
hc_url="$(env_val EDEN_HEALTHCHECK_URL)"

state="/tmp/eden-monitor"; mkdir -p "${state}"
debounce=21600   # 6h — re-alert a still-bad condition at most this often, so cron doesn't spam

# alert <key> <message>: debounced per key; sends to Telegram when configured, always logs.
alert() {
  local marker="${state}/$1"
  if [ -f "${marker}" ] && [ "$(( $(date +%s) - $(stat -c %Y "${marker}" 2>/dev/null || echo 0) ))" -lt "${debounce}" ]; then
    return
  fi
  echo "$(date '+%F %T') ALERT[$1] $2" >&2
  if [ -n "${tg_token}" ] && [ -n "${tg_chat}" ]; then
    # Keep the bot token OFF the process argv (ps auxww / docker inspect) — pass the URL
    # (which carries the token) via `curl -K -` on stdin, not as a command-line argument.
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "${tg_token}" \
      | curl -sS --max-time 15 -K - \
          --data-urlencode chat_id="${tg_chat}" \
          --data-urlencode text="🚨 eden: $2" >/dev/null 2>&1
  fi
  touch "${marker}"
}
recovered() { rm -f "${state}/$1"; }   # condition cleared → allow an immediate alert next time

healthy=1

# 1. Disk (Docker's data dir holds images + the pgdata/uploads volumes).
used="$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
used="${used:-0}"
if [ "${used}" -ge "${disk_pct}" ]; then
  healthy=0
  alert disk "disk at ${used}% (>= ${disk_pct}%) — move media to R2 / prune before Postgres stalls"
else
  recovered disk
fi

# 2. App health via the container's own healthcheck (port 4000 isn't exposed to the host).
cid="$(docker compose ps -q app 2>/dev/null || true)"
if [ -z "${cid}" ]; then
  healthy=0
  alert app "app container is not running — check \`docker compose ps\`"
else
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${cid}" 2>/dev/null || true)"
  case "${status}" in
    healthy | running) recovered app ;;
    *) healthy=0; alert app "app is '${status:-unknown}' — check \`docker compose ps\` / logs" ;;
  esac
fi

# 3. Dead-man switch — ping only when everything is healthy, so a full-box outage stops the pings.
if [ "${healthy}" = 1 ] && [ -n "${hc_url}" ]; then
  curl -sS --max-time 15 "${hc_url}" >/dev/null 2>&1 || true
fi
