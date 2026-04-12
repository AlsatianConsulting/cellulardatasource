#!/usr/bin/env bash
# Inject cell datasource definitions into a running Kismet instance via HTTP API.
set -euo pipefail

SOURCE_FILE="${SOURCE_FILE:-/var/lib/kismet/cell/sources.generated}"
KISMET_URL="${KISMET_URL:-http://127.0.0.1:2501}"
AUTH_FILE="${AUTH_FILE:-/var/lib/kismet/.kismet/kismet_httpd.conf}"
MAX_WAIT_SECS="${MAX_WAIT_SECS:-30}"
ADD_ONCE_FLAG="${ADD_ONCE_FLAG:-/var/lib/kismet/cell/source-added.flag}"

log() { printf '[cell-injector] %s\n' "$*"; }

read_auth() {
  local user pass
  if [[ -f "${AUTH_FILE}" ]]; then
    user="$(sed -n 's/^[[:space:]]*httpd_username[[:space:]]*=[[:space:]]*//p' "${AUTH_FILE}" | tail -n1)"
    pass="$(sed -n 's/^[[:space:]]*httpd_password[[:space:]]*=[[:space:]]*//p' "${AUTH_FILE}" | tail -n1)"
    if [[ -n "${user}" && -n "${pass}" ]]; then
      echo "${user}:${pass}"
      return 0
    fi
  fi
  echo ""
  return 0
}

api_get() {
  local path="$1"
  if [[ -n "${AUTH_CRED}" ]]; then
    curl -fsS -u "${AUTH_CRED}" "${KISMET_URL}${path}"
  else
    curl -fsS "${KISMET_URL}${path}"
  fi
}

api_post_json() {
  local path="$1"
  local json_payload="$2"
  if [[ -n "${AUTH_CRED}" ]]; then
    curl -fsS -u "${AUTH_CRED}" --data-urlencode "json=${json_payload}" "${KISMET_URL}${path}"
  else
    curl -fsS --data-urlencode "json=${json_payload}" "${KISMET_URL}${path}"
  fi
}

if [[ ! -s "${SOURCE_FILE}" ]]; then
  log "No source file at ${SOURCE_FILE}; nothing to inject"
  exit 0
fi

if [[ -f "${ADD_ONCE_FLAG}" ]]; then
  log "Add-once flag exists (${ADD_ONCE_FLAG}); skipping datasource add"
  exit 0
fi

AUTH_CRED="$(read_auth)"

ready=0
for _ in $(seq 1 "${MAX_WAIT_SECS}"); do
  if api_get "/system/status.json" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "${ready}" -ne 1 ]]; then
  log "Kismet API not ready at ${KISMET_URL}; skipping for now"
  exit 0
fi

existing_json="$(api_get "/datasource/all_sources.json" 2>/dev/null || echo "[]")"
existing_names="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
names = set()
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(k, str) and k.endswith("datasource.name") and isinstance(v, str):
                names.add(v)
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(data)
print("\n".join(sorted(names)))
' <<< "${existing_json}")"

added=0
failed=0
present=0
attempted=0

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^# ]] && continue
  [[ "${line}" =~ ^source= ]] || continue

  definition="${line#source=}"
  attempted=$((attempted + 1))
  name="$(printf '%s\n' "${definition}" | sed -n 's/.*name=\([^,]*\).*/\1/p' | head -n1)"
  if [[ -n "${name}" ]] && printf '%s\n' "${existing_names}" | grep -Fxq "${name}"; then
    present=$((present + 1))
    continue
  fi

  payload="$(python3 -c 'import json,sys; print(json.dumps({"definition": sys.argv[1]}))' "${definition}")"

  if ! response="$(api_post_json "/datasource/add_source.cmd" "${payload}" 2>&1)"; then
    log "add_source request failed for ${name:-unknown}: ${response}"
    failed=$((failed + 1))
    continue
  fi
  if printf '%s' "${response}" | grep -Eqi "Unable to find datasource for 'cell'|Unable to find driver for 'cell'"; then
    # Plugin load/probe availability can lag behind startup; let periodic autosetup try again.
    log "cell datasource driver not available yet; will retry on next run"
    failed=$((failed + 1))
    continue
  fi
  if printf '%s' "${response}" | grep -qi "error"; then
    log "add_source returned error for ${name:-unknown}: ${response}"
    failed=$((failed + 1))
    continue
  fi
  added=$((added + 1))
done < "${SOURCE_FILE}"

if [[ "${failed}" -eq 0 && ( "${added}" -gt 0 || ( "${attempted}" -gt 0 && "${present}" -eq "${attempted}" ) ) ]]; then
  mkdir -p "$(dirname "${ADD_ONCE_FLAG}")"
  touch "${ADD_ONCE_FLAG}"
  log "Marked add-once complete (${ADD_ONCE_FLAG})"
fi

log "Datasource injection complete: added=${added} failed=${failed}"
exit 0
