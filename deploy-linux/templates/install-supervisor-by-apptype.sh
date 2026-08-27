#!/usr/bin/env bash
#
# install-supervisor-by-apptype.sh
#
# Clone of install-supervisor-default.sh with APP_TYPE-scoped credentials:
# only the env vars for the selected app.type are required / written.
# Everything else (Supervisor install, Fleet tags, agent.env wiring) is the same.
#
# Supported APP_TYPE values:
#   postgresql | redis | valkey | elasticsearch | databases
#
# Examples:
#   # Postgres host — only Postgres vars required
#   sudo env \
#     CORALOGIX_PRIVATE_KEY="<key>" \
#     CORALOGIX_DOMAIN="eu2.coralogix.com" \
#     APP_TYPE="postgresql" ENV_TYPE="prod" \
#     POSTGRES_OTEL_PASSWORD="<password>" \
#     POSTGRES_OTEL_USER="otel_monitor" \
#     POSTGRES_OTEL_DATABASE="appdb" \
#     POSTGRES_ENDPOINT="localhost:5432" \
#     ./install-supervisor-by-apptype.sh
#
#   # Redis host — Redis vars only (password optional / empty OK)
#   sudo env \
#     CORALOGIX_PRIVATE_KEY="<key>" \
#     CORALOGIX_DOMAIN="eu2.coralogix.com" \
#     APP_TYPE="redis" ENV_TYPE="prod" \
#     REDIS_ENDPOINT="localhost:6379" \
#     REDIS_PASSWORD="" \
#     ./install-supervisor-by-apptype.sh
#
#   # Elasticsearch host — username and password required
#   sudo env \
#     CORALOGIX_PRIVATE_KEY="<key>" \
#     CORALOGIX_DOMAIN="eu2.coralogix.com" \
#     APP_TYPE="elasticsearch" ENV_TYPE="prod" \
#     ELASTICSEARCH_ENDPOINT="http://localhost:9200" \
#     ELASTICSEARCH_USERNAME="elastic" \
#     ELASTICSEARCH_PASSWORD="<password>" \
#     ./install-supervisor-by-apptype.sh
#
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

: "${CORALOGIX_PRIVATE_KEY:?Set CORALOGIX_PRIVATE_KEY}"
: "${CORALOGIX_DOMAIN:?Set CORALOGIX_DOMAIN (e.g. eu2.coralogix.com)}"

# Fleet Management selection attributes
APP_TYPE="${APP_TYPE:-databases}"
ENV_TYPE="${ENV_TYPE:-databases}"
# Normalize for matching (customers may pass PostgreSQL / REDIS)
APP_TYPE_NORM="$(printf '%s' "${APP_TYPE}" | tr '[:upper:]' '[:lower:]')"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: ${name} is required when APP_TYPE=${APP_TYPE}." >&2
    exit 1
  fi
}

require_pair_or_empty() {
  local first_name="$1"
  local second_name="$2"

  if [[ (-n "${!first_name:-}" && -z "${!second_name:-}") ||
        (-z "${!first_name:-}" && -n "${!second_name:-}") ]]; then
    echo "ERROR: ${first_name} and ${second_name} must both be empty or both be non-empty." >&2
    exit 1
  fi
}

# Credentials / endpoints to persist + pass into collector (filled per APP_TYPE)
CRED_KEYS=()
PASS_THROUGH_KEYS=("APP_TYPE" "ENV_TYPE")

case "${APP_TYPE_NORM}" in
  postgresql|postgres)
    APP_TYPE="postgresql"
    : "${POSTGRES_ENDPOINT:=localhost:5432}"
    : "${POSTGRES_OTEL_USER:=otel_monitor}"
    : "${POSTGRES_OTEL_DATABASE:=appdb}"
    require_var POSTGRES_OTEL_PASSWORD
    CRED_KEYS=(
      POSTGRES_ENDPOINT
      POSTGRES_OTEL_USER
      POSTGRES_OTEL_PASSWORD
      POSTGRES_OTEL_DATABASE
    )
    ;;
  redis)
    APP_TYPE="redis"
    : "${REDIS_ENDPOINT:=localhost:6379}"
    : "${REDIS_PASSWORD:=}"
    CRED_KEYS=(
      REDIS_ENDPOINT
      REDIS_PASSWORD
    )
    ;;
  valkey)
    APP_TYPE="valkey"
    : "${VALKEY_ENDPOINT:=localhost:6380}"
    : "${VALKEY_PASSWORD:=}"
    CRED_KEYS=(
      VALKEY_ENDPOINT
      VALKEY_PASSWORD
    )
    ;;
  elasticsearch|elastic|es)
    APP_TYPE="elasticsearch"
    : "${ELASTICSEARCH_ENDPOINT:=http://localhost:9200}"
    require_var ELASTICSEARCH_USERNAME
    require_var ELASTICSEARCH_PASSWORD
    CRED_KEYS=(
      ELASTICSEARCH_ENDPOINT
      ELASTICSEARCH_USERNAME
      ELASTICSEARCH_PASSWORD
    )
    ;;
  databases|all|mixed)
    APP_TYPE="databases"
    : "${REDIS_ENDPOINT:=localhost:6379}"
    : "${REDIS_PASSWORD:=}"
    : "${VALKEY_ENDPOINT:=localhost:6380}"
    : "${VALKEY_PASSWORD:=}"
    : "${POSTGRES_ENDPOINT:=localhost:5432}"
    : "${POSTGRES_OTEL_USER:=otel_monitor}"
    : "${POSTGRES_OTEL_DATABASE:=appdb}"
    : "${ELASTICSEARCH_ENDPOINT:=http://localhost:9200}"
    : "${ELASTICSEARCH_USERNAME:=}"
    : "${ELASTICSEARCH_PASSWORD:=}"
    require_var POSTGRES_OTEL_PASSWORD
    require_pair_or_empty ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD
    CRED_KEYS=(
      REDIS_ENDPOINT
      REDIS_PASSWORD
      VALKEY_ENDPOINT
      VALKEY_PASSWORD
      POSTGRES_ENDPOINT
      POSTGRES_OTEL_USER
      POSTGRES_OTEL_PASSWORD
      POSTGRES_OTEL_DATABASE
      ELASTICSEARCH_ENDPOINT
      ELASTICSEARCH_USERNAME
      ELASTICSEARCH_PASSWORD
    )
    ;;
  *)
    echo "ERROR: unsupported APP_TYPE='${APP_TYPE}'." >&2
    echo "  Use one of: postgresql, redis, valkey, elasticsearch, databases" >&2
    exit 1
    ;;
esac

PASS_THROUGH_KEYS+=("${CRED_KEYS[@]}")

# Strip accidental protocol / trailing slash
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN#https://}"
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN#http://}"
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN%/}"

INSTALLER_URL="${INSTALLER_URL:-https://github.com/coralogix/telemetry-shippers/releases/latest/download/coralogix-otel-collector.sh}"
SUPERVISOR_CONFIG="/etc/opampsupervisor/config.yaml"
SUPERVISOR_ENV="/etc/opampsupervisor/opampsupervisor.conf"
CRED_MARKER_BEGIN="# BEGIN install-supervisor-by-apptype credentials"
CRED_MARKER_END="# END install-supervisor-by-apptype credentials"

systemd_env_entry() {
  local key="$1"
  local value="$2"

  # Unix environment variables cannot contain NUL; reject line delimiters here.
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "ERROR: ${key} contains CR/LF and cannot be stored in an EnvironmentFile." >&2
    return 1
  fi

  # In systemd double quotes, backslash escapes \, ", $, and `.
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '%s="%s"\n' "${key}" "${value}"
}

MANAGED_KEYS=("APP_TYPE" "ENV_TYPE" "${CRED_KEYS[@]}")
SYSTEMD_ENV_ENTRIES=()
for key in "${MANAGED_KEYS[@]}"; do
  SYSTEMD_ENV_ENTRIES+=("$(systemd_env_entry "${key}" "${!key}")")
done

echo "==> Installing Coralogix OTel Collector in Supervisor mode (installer defaults, no base config)"
echo "    Domain  : ${CORALOGIX_DOMAIN}"
echo "    app.type: ${APP_TYPE}"
echo "    env.type: ${ENV_TYPE}"
echo "    Credential keys for this APP_TYPE:"
for key in "${CRED_KEYS[@]}"; do
  if [[ "${key}" == *PASSWORD* ]]; then
    echo "      - ${key}=******"
  else
    echo "      - ${key}=${!key}"
  fi
done

CORALOGIX_PRIVATE_KEY="${CORALOGIX_PRIVATE_KEY}" \
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN}" \
  bash -c "$(curl -fsSL "${INSTALLER_URL}")" \
  -- --supervisor

if [[ ! -f "${SUPERVISOR_CONFIG}" ]]; then
  echo "ERROR: ${SUPERVISOR_CONFIG} not found after installer." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Persist credentials for systemd / supervisor (APP_TYPE-scoped only)
# -----------------------------------------------------------------------------
echo "==> Writing receiver credentials to ${SUPERVISOR_ENV}"
(
  umask 077
  touch "${SUPERVISOR_ENV}"
  chmod 0600 "${SUPERVISOR_ENV}"
  if grep -q "${CRED_MARKER_BEGIN}" "${SUPERVISOR_ENV}" 2>/dev/null; then
    rewrite_tmp="$(mktemp "${SUPERVISOR_ENV}.tmp.XXXXXX")"
    trap 'rm -f -- "${rewrite_tmp}"' EXIT
    awk -v start="${CRED_MARKER_BEGIN}" -v end="${CRED_MARKER_END}" '
      $0 == start {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    ' "${SUPERVISOR_ENV}" >"${rewrite_tmp}"
    mv "${rewrite_tmp}" "${SUPERVISOR_ENV}"
    trap - EXIT
  fi

  # Drop keys we manage so re-runs stay clean
  for key in "${MANAGED_KEYS[@]}"; do
    sed -i -e "/^${key}=/d" "${SUPERVISOR_ENV}"
  done

  {
    echo ""
    echo "${CRED_MARKER_BEGIN}"
    printf '%s\n' "${SYSTEMD_ENV_ENTRIES[@]}"
    echo "${CRED_MARKER_END}"
  } >>"${SUPERVISOR_ENV}"
  chmod 0600 "${SUPERVISOR_ENV}"
)

# -----------------------------------------------------------------------------
# Patch supervisor config: Fleet attrs + pass only relevant env vars to collector
# -----------------------------------------------------------------------------
echo "==> Patching ${SUPERVISOR_CONFIG} (Fleet attributes + agent.env pass-through)"
PASS_THROUGH_CSV="$(IFS=,; echo "${PASS_THROUGH_KEYS[*]}")"
APP_TYPE="${APP_TYPE}" ENV_TYPE="${ENV_TYPE}" PASS_THROUGH_CSV="${PASS_THROUGH_CSV}" \
python3 - "${SUPERVISOR_CONFIG}" <<'PY'
import os, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
app_type = os.environ["APP_TYPE"]
env_type = os.environ["ENV_TYPE"]
pass_through = [k for k in os.environ["PASS_THROUGH_CSV"].split(",") if k]

def upsert_attr(text: str, key: str, value: str) -> str:
    attr_re = re.compile(rf'(?m)^(\s*)(?:{re.escape(key)}|"{re.escape(key)}"):\s*.*$')
    m = re.search(r'(?m)^(\s*)non_identifying_attributes:\s*$', text)
    indent = (m.group(1) + "  ") if m else "      "
    new_line = f'{indent}{key}: "{value}"'
    if attr_re.search(text):
        return attr_re.sub(new_line, text, count=1)
    if m:
        return re.sub(
            r'(?m)^(\s*)non_identifying_attributes:\s*$',
            lambda mm: mm.group(0) + "\n" + new_line,
            text,
            count=1,
        )
    raise SystemExit(
        "Could not find description.non_identifying_attributes in supervisor config"
    )

def upsert_agent_env(text: str, key: str) -> str:
    """Ensure agent.env has: KEY: "${env:KEY}" """
    line_re = re.compile(rf'(?m)^(\s*){re.escape(key)}:\s*.*$')
    new_line = f'    {key}: "${{env:{key}}}"'
    if line_re.search(text):
        return line_re.sub(new_line, text, count=1)
    if re.search(r'(?m)^(\s*)CORALOGIX_PRIVATE_KEY:\s*', text):
        return re.sub(
            r'(?m)^(\s*)CORALOGIX_PRIVATE_KEY:\s*.*$',
            lambda m: m.group(0) + "\n" + new_line,
            text,
            count=1,
        )
    if re.search(r'(?m)^(\s*)env:\s*$', text):
        return re.sub(
            r'(?m)^(\s*)env:\s*$',
            lambda m: m.group(0) + "\n" + new_line,
            text,
            count=1,
        )
    raise SystemExit("Could not find agent.env in supervisor config")

text = upsert_attr(text, "app.type", app_type)
text = upsert_attr(text, "env.type", env_type)
for key in pass_through:
    text = upsert_agent_env(text, key)

path.write_text(text, encoding="utf-8")
print(f"Set app.type={app_type!r}, env.type={env_type!r}")
print(f"Pass-through env keys: {', '.join(pass_through)}")
PY

echo "==> Restarting opampsupervisor"
systemctl daemon-reload
systemctl restart opampsupervisor

for _ in $(seq 1 20); do
  if systemctl is-active --quiet opampsupervisor; then
    break
  fi
  sleep 1
done
systemctl is-active --quiet opampsupervisor || {
  echo "ERROR: opampsupervisor is not active. Check: journalctl -u opampsupervisor -e" >&2
  exit 1
}

sleep 3
if journalctl -u opampsupervisor -n 40 --no-pager 2>/dev/null | grep -q "missing password\|exited unexpectedly"; then
  echo "WARN: collector may still be failing — check:"
  echo "  sudo tail -n 50 /var/log/opampsupervisor/opampsupervisor.log"
else
  echo "==> Supervisor is active (no recent 'missing password' / crash in last log slice)"
fi

echo
echo "==> Done."
echo "    Service  : systemctl status opampsupervisor"
echo "    Logs     : journalctl -u opampsupervisor -f"
echo "               tail -f /var/log/opampsupervisor/opampsupervisor.log"
echo "    Supervisor config : ${SUPERVISOR_CONFIG}"
echo "    Credentials       : ${SUPERVISOR_ENV}"
echo "    Effective config  : /var/lib/opampsupervisor/effective.yaml"
echo "    app.type : ${APP_TYPE}"
echo "    env.type : ${ENV_TYPE}"
echo
echo "Verify metrics (after Fleet remote config is applied):"
echo "  curl -s http://127.0.0.1:8888/metrics | head -20"
echo
echo "In Coralogix:"
echo "  Integrations → Fleet Management → Agents → Group by app.type / env.type"
echo "  Configurations → Agent selector → Activate (Remote configuration enabled)"
