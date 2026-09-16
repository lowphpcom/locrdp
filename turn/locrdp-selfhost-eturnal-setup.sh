#!/usr/bin/env bash
set -Eeuo pipefail

# This installer is intentionally separate from locrdp-eturnal-setup.sh.
# It installs an unmetered, user-owned TURN server and binds it to one locrdp account.

API_BASE_URL="${LOCRDP_API_BASE_URL:-https://api.locrdp.cn}"
AUTHORIZE_URL="${API_BASE_URL%/}/self-hosted-turn/authorize"
REGISTER_URL="${API_BASE_URL%/}/self-hosted-turn/register"
CONFIG_FILE="/etc/eturnal.yml"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/eturnal.service.d"
SYSTEMD_DROPIN_FILE="${SYSTEMD_DROPIN_DIR}/99-locrdp-selfhost-throughput.conf"
SYSCTL_FILE="/etc/sysctl.d/99-locrdp-selfhost-eturnal.conf"
TURN_PORT="${TURN_PORT:-3478}"
RELAY_MIN_PORT="${RELAY_MIN_PORT:-49152}"
RELAY_MAX_PORT="${RELAY_MAX_PORT:-65535}"
REALM="${REALM:-locrdp-selfhost}"
TURN_NAME="${SELFHOST_TURN_NAME:-}"
TURN_AREA="${SELFHOST_TURN_AREA:-self}"
TURN_TTL="${TURN_CREDENTIAL_TTL:-3600}"
PUBLIC_IP="${PUBLIC_IP:-}"
ACCOUNT="${LOCRDP_ACCOUNT:-}"
PASSWORD="${LOCRDP_PASSWORD:-}"
SERVER_KEY=""
AUTH_SECRET=""
ENROLLMENT_TOKEN=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [ "$( id -u )" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
}

require_tools() {
  local tool
  for tool in curl openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少依赖 ${tool}。请先安装 ${tool} 后再运行。"
  done
}

require_debian() {
  [ -r /etc/os-release ] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "debian" ] || die "此自建中继脚本要求 Debian。"
}

validate_ports() {
  [[ "${API_BASE_URL}" =~ ^https:// ]] || die "自建中继 API 必须使用 HTTPS。"
  [[ "${TURN_PORT}" =~ ^[0-9]+$ ]] && [ "${TURN_PORT}" -ge 1 ] && [ "${TURN_PORT}" -le 65535 ] || die "TURN_PORT 无效。"
  [[ "${RELAY_MIN_PORT}" =~ ^[0-9]+$ ]] && [ "${RELAY_MIN_PORT}" -ge 1 ] && [ "${RELAY_MIN_PORT}" -le 65535 ] || die "RELAY_MIN_PORT 无效。"
  [[ "${RELAY_MAX_PORT}" =~ ^[0-9]+$ ]] && [ "${RELAY_MAX_PORT}" -ge 1 ] && [ "${RELAY_MAX_PORT}" -le 65535 ] || die "RELAY_MAX_PORT 无效。"
  [ "${RELAY_MIN_PORT}" -le "${RELAY_MAX_PORT}" ] || die "RELAY_MIN_PORT 不能大于 RELAY_MAX_PORT。"
  [[ "${TURN_TTL}" =~ ^[0-9]+$ ]] && [ "${TURN_TTL}" -ge 300 ] && [ "${TURN_TTL}" -le 3600 ] || die "TURN_CREDENTIAL_TTL must be between 300 and 3600 seconds."
}

prompt_credentials() {
  if [ -z "${ACCOUNT}" ]; then
    read -r -p "locrdp 账号或手机号: " ACCOUNT
  fi
  if [ -z "${PASSWORD}" ]; then
    read -r -s -p "locrdp 密码: " PASSWORD
    echo
  fi
  [ -n "${ACCOUNT}" ] && [ -n "${PASSWORD}" ] || die "账号和密码不能为空。"
}

authorize_account() {
  local payload response
  payload="$(printf '%s\0%s' "${ACCOUNT}" "${PASSWORD}" | python3 -c '
import json
import sys
account, password = sys.stdin.buffer.read().split(b"\0", 1)
print(json.dumps({"account": account.decode(), "password": password.decode()}, ensure_ascii=False))
')"
  response="$(printf '%s' "${payload}" | curl -fsS --connect-timeout 10 --max-time 30 \
    -H 'Content-Type: application/json' \
    --data-binary @- "${AUTHORIZE_URL}")" || die "账号验证请求失败。"
  unset PASSWORD

  read -r SERVER_KEY AUTH_SECRET ENROLLMENT_TOKEN <<EOF
$(printf '%s' "${response}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit("API 返回不是有效 JSON")
if data.get("status") != "success":
    raise SystemExit(data.get("message") or "账号验证失败")
for key in ("server_key", "auth_secret", "enrollment_token"):
    if not data.get(key):
        raise SystemExit("API 返回缺少 " + key)
print(data["server_key"], data["auth_secret"], data["enrollment_token"])
')
EOF
  [[ "${SERVER_KEY}" =~ ^self-[a-f0-9]{16}$ ]] || die "API 返回的自建中继编号无效。"
  [[ "${AUTH_SECRET}" =~ ^[a-f0-9]{64}$ ]] || die "API 返回的中继密钥无效。"
  [[ "${ENROLLMENT_TOKEN}" =~ ^[a-f0-9]{64}$ ]] || die "API 返回的绑定令牌无效。"
  echo "账号验证通过。自建中继安装开始。"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl python3
}

is_valid_ipv4() {
  local ip="${1:-}" a b c d extra octet
  [[ "${ip}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS=. read -r a b c d extra <<< "${ip}"
  [ -z "${extra:-}" ] || return 1
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    [ "${octet}" -ge 0 ] 2>/dev/null && [ "${octet}" -le 255 ] 2>/dev/null || return 1
  done
}

detect_public_ip() {
  if [ -n "${PUBLIC_IP}" ]; then
    is_valid_ipv4 "${PUBLIC_IP}" || die "PUBLIC_IP 无效。"
    return
  fi
  local endpoint response ip=""
  for endpoint in https://4.ipw.cn https://ip.3322.net https://myip.ipip.net; do
    response="$( curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 10 "${endpoint}" 2>/dev/null || true)"
    ip="$(printf '%s\n' "${response}" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)"
    if is_valid_ipv4 "${ip}"; then
      PUBLIC_IP="${ip}"
      break
    fi
  done
  is_valid_ipv4 "${PUBLIC_IP}" || die "无法检测公网 IPv4，请设置 PUBLIC_IP 后重试。"
}

prepare_values() {
  if [ -z "${TURN_NAME}" ]; then
    TURN_NAME="$( hostname -s 2>/dev/null || true)"
  fi
  TURN_NAME="$(printf '%s' "${TURN_NAME}" | python3 -c 'import sys; print(sys.stdin.read().strip())')"
  TURN_NAME="${TURN_NAME:-locrdp 自建中继}"
  [ "${#TURN_NAME}" -le 128 ] || die "SELFHOST_TURN_NAME 不能超过 128 个字符。"
  [[ "${TURN_AREA}" =~ ^[a-z]{2,16}$ ]] || die "SELFHOST_TURN_AREA 必须是 2-16 位小写字母。"
}

install_eturnal() {
  echo "正在安装 eturnal..."
  curl -fsS --connect-timeout 10 --max-time 300 https://eturnal.net/install | sh
  if [ -x /opt/eturnal/bin/eturnalctl ] && ! command -v eturnalctl >/dev/null 2>&1; then
    ln -sf /opt/eturnal/bin/eturnalctl /usr/local/bin/eturnalctl
  fi
  command -v eturnalctl >/dev/null 2>&1 || [ -x /opt/eturnal/bin/eturnalctl ] || die "eturnal 安装失败。"
}

tune_system() {
  modprobe tcp_bbr 2>/dev/null || true
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cat >"${SYSCTL_FILE}" <<'EOF'
net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 10000
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p "${SYSCTL_FILE}" >/dev/null || true
  fi
}

write_config() {
  [ ! -f "${CONFIG_FILE}" ] || cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cat >"${CONFIG_FILE}" <<EOF
eturnal:
  listen:
    -
      ip: "0.0.0.0"
      port: ${TURN_PORT}
      transport: udp
    -
      ip: "0.0.0.0"
      port: ${TURN_PORT}
      transport: tcp
  realm: "${REALM}"
  secret: "${AUTH_SECRET}"
  relay_ipv4_addr: "${PUBLIC_IP}"
  relay_min_port: ${RELAY_MIN_PORT}
  relay_max_port: ${RELAY_MAX_PORT}
  strict_expiry: true
  log_level: warning
  log_dir: stdout
EOF
  chmod 0644 "${CONFIG_FILE}"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${TURN_PORT}/udp" >/dev/null || true
    ufw allow "${TURN_PORT}/tcp" >/dev/null || true
    ufw allow "${RELAY_MIN_PORT}:${RELAY_MAX_PORT}/udp" >/dev/null || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${TURN_PORT}/udp" >/dev/null || true
    firewall-cmd --permanent --add-port="${TURN_PORT}/tcp" >/dev/null || true
    firewall-cmd --permanent --add-port="${RELAY_MIN_PORT}-${RELAY_MAX_PORT}/udp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
}

restart_service() {
  install -d -m 0755 "${SYSTEMD_DROPIN_DIR}"
  cat >"${SYSTEMD_DROPIN_FILE}" <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
EOF
  systemctl daemon-reload
  systemctl enable eturnal
  systemctl restart eturnal
  systemctl is-active --quiet eturnal || {
    journalctl -u eturnal --no-pager -n 80 || true
    die "eturnal 启动失败。"
  }
}

register_server() {
  local timestamp urls canonical signature payload response
  timestamp="$(date +%s)"
  urls="$(printf '["turn:%s:%s?transport=udp","turn:%s:%s?transport=tcp"]' "${PUBLIC_IP}" "${TURN_PORT}" "${PUBLIC_IP}" "${TURN_PORT}")"
  canonical="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' "${timestamp}" "${SERVER_KEY}" "${TURN_NAME}" "${TURN_AREA}" "${urls}" "${AUTH_SECRET}" "${TURN_TTL}")"
  signature="$(printf '%s' "${canonical}" | openssl dgst -sha256 -hmac "${ENROLLMENT_TOKEN}" | awk '{print $NF}')"
  payload="$( python3 - "${SERVER_KEY}" "${TURN_NAME}" "${TURN_AREA}" "${urls}" "${AUTH_SECRET}" "${TURN_TTL}" "${timestamp}" "${ENROLLMENT_TOKEN}" <<'PY'
import json
import sys
key, name, area, urls, secret, ttl, timestamp, token = sys.argv[1:]
print(json.dumps({
    "server_key": key, "server_name": name, "area": area,
    "urls": json.loads(urls), "auth_secret": secret,
    "credential_ttl": ttl, "timestamp": timestamp,
    "enrollment_token": token,
}, ensure_ascii=False))
PY
)"
  response="$(printf '%s' "${payload}" | curl -fsS --connect-timeout 10 --max-time 30 \
    -H 'Content-Type: application/json' \
    -H "X-Locrdp-Selfhost-Signature: ${signature}" \
    --data-binary @- "${REGISTER_URL}")" || die "自建中继绑定请求失败。"
  printf '%s' "${response}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("status") != "success":
    raise SystemExit(data.get("message") or "自建中继绑定失败")
' || die "自建中继绑定失败。"
}

print_result() {
  echo
  echo "自建中继已安装并绑定到 locrdp 账号。"
  echo "TURN URL:"
  echo "turn:${PUBLIC_IP}:${TURN_PORT}?transport=udp"
  echo "turn:${PUBLIC_IP}:${TURN_PORT}?transport=tcp"
  echo "TURN server key: ${SERVER_KEY}"
  echo "本脚本不安装官方配额模块、流量上报模块或会话限速补丁。"
  echo "Config: ${CONFIG_FILE}"
  echo "请在云安全组放行 UDP/TCP ${TURN_PORT} 和 UDP ${RELAY_MIN_PORT}-${RELAY_MAX_PORT}。"
}

main() {
  need_root
  require_debian
  install_packages
  require_tools
  validate_ports
  prompt_credentials
  prepare_values
  detect_public_ip
  tune_system
  install_eturnal
  # Enrollment expires quickly; request it only once package installation has finished.
  authorize_account
  write_config
  open_firewall
  restart_service
  register_server
  print_result
}

main "$@"
