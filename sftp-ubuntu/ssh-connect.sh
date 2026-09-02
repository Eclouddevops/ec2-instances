#!/usr/bin/env bash
# ==============================================================================
# ssh-connect.sh – Connect to sftp-ubuntu EC2 via SSH
#
# Instance is in a PUBLIC subnet with a permanent Elastic IP.
# Direct SSH – no tunnel, no bastion, no EICE proxy needed.
#
# This script does everything in one shot:
#   1. Fetches the SSH private key from AWS Secrets Manager
#   2. Saves it as ~/sftp-ubuntu.pem (chmod 400)
#   3. Looks up the Elastic IP of the instance automatically
#   4. Opens SSH directly to the public IP
#
# Usage:
#   sh ssh-connect.sh            # fetch key + connect
#   sh ssh-connect.sh --keep-key # reuse existing ~/sftp-ubuntu.pem
#   sh ssh-connect.sh --show-cmd # print the ssh command only, don't connect
#   sh ssh-connect.sh --help     # show this help
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
INSTANCE_NAME="sftp-ubuntu"
REGION="ap-south-1"
PROFILE="CoreProdWorkloadAccount"
SECRET_ID="sftp-ubuntu/ssh-private-key"
SSH_USER="ubuntu"
KEY_FILE="${HOME}/sftp-ubuntu.pem"
PORTABLE_BIN="${HOME}/bin"
# ──────────────────────────────────────────────────────────────────────────────

mkdir -p "$PORTABLE_BIN"
export PATH="${PORTABLE_BIN}:${PATH}"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Platform detection ─────────────────────────────────────────────────────────
OS_TYPE=$(uname -s 2>/dev/null || echo "Linux")
ARCH=$(uname -m 2>/dev/null || echo "x86_64")
IS_WINDOWS=false
echo "${OS_TYPE}" | grep -qiE "MINGW|MSYS|CYGWIN" && IS_WINDOWS=true || true
echo "${HOME}" | grep -qE '^/[a-zA-Z]/' && IS_WINDOWS=true || true

# ── jq: portable, no admin ────────────────────────────────────────────────────
JQ_BIN="jq"
setup_jq() {
  command -v jq &>/dev/null         && JQ_BIN="jq"                        && return
  [[ -x "${PORTABLE_BIN}/jq" ]]     && JQ_BIN="${PORTABLE_BIN}/jq"        && return
  [[ -x "${PORTABLE_BIN}/jq.exe" ]] && JQ_BIN="${PORTABLE_BIN}/jq.exe"    && return

  warn "jq not found – downloading portable binary..."
  local url dest
  if [[ "$IS_WINDOWS" == "true" ]]; then
    url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
    dest="${PORTABLE_BIN}/jq.exe"
  else
    case "$ARCH" in
      x86_64)        url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" ;;
      aarch64|arm64) url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64" ;;
      *) die "Unsupported arch ${ARCH}." ;;
    esac
    dest="${PORTABLE_BIN}/jq"
  fi
  _dl "$url" "$dest" && chmod +x "$dest"
  JQ_BIN="$dest"
  "$JQ_BIN" --version &>/dev/null || die "jq setup failed."
  ok "jq ready: ${JQ_BIN}"
}

_dl() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then curl -fsSL "$url" -o "$dest"
  elif command -v wget &>/dev/null; then wget -q "$url" -O "$dest"
  else die "curl/wget not found."; fi
}

# ── AWS wrapper ────────────────────────────────────────────────────────────────
aws_cmd() { aws --region "$REGION" --profile "$PROFILE" "$@"; }

# ── Step 1: Retrieve SSH key ───────────────────────────────────────────────────
fetch_key() {
  local keep="${1:-false}"
  if [[ "$keep" == "true" && -f "$KEY_FILE" ]]; then
    ok "Reusing existing key: ${KEY_FILE}"; return
  fi

  section "Step 1 – Fetching SSH Key from Secrets Manager"
  log "Secret  : ${SECRET_ID}"
  log "Key file: ${KEY_FILE}"

  [[ -f "$KEY_FILE" ]] && { warn "Removing old key..."; rm -f "$KEY_FILE"; }

  local secret
  secret=$(aws_cmd secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>&1) \
    || die "Cannot retrieve secret.\nError: ${secret}"

  local private_key
  private_key=$(echo "$secret" | "$JQ_BIN" -r '.private_key') \
    || die "Failed to parse private_key from secret JSON."

  [[ -z "$private_key" || "$private_key" == "null" ]] \
    && die "private_key is empty in secret '${SECRET_ID}'."
  echo "$private_key" | grep -q "BEGIN.*PRIVATE KEY" \
    || die "Value is not a valid PEM private key."

  printf '%s\n' "$private_key" > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ok "Key saved: ${KEY_FILE} (chmod 400)"
}

# ── Step 2: Look up instance and public IP ─────────────────────────────────────
fetch_instance_info() {
  section "Step 2 – Looking Up Instance"

  INSTANCE_ID=$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null)
  [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]] \
    && die "Instance '${INSTANCE_NAME}' not found or not running in ${REGION}."

  INSTANCE_STATE=$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)

  PRIVATE_IP=$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text)

  # Get Elastic IP (permanent public IP) associated with the instance
  ELASTIC_IP=$(aws_cmd ec2 describe-addresses \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --query "Addresses[0].PublicIp" \
    --output text 2>/dev/null || echo "None")

  # Fallback to auto-assigned public IP if EIP is not yet associated
  if [[ -z "$ELASTIC_IP" || "$ELASTIC_IP" == "None" ]]; then
    warn "No Elastic IP found – using auto-assigned public IP..."
    ELASTIC_IP=$(aws_cmd ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text 2>/dev/null || echo "")
  fi

  [[ -z "$ELASTIC_IP" || "$ELASTIC_IP" == "None" ]] \
    && die "No public IP found on instance. Make sure it is in a public subnet with an IGW route."

  log "Instance ID : ${INSTANCE_ID}"
  log "State       : ${INSTANCE_STATE}"
  log "Private IP  : ${PRIVATE_IP}"
  log "Public IP   : ${ELASTIC_IP} (Elastic/Static)"
  ok  "Instance found and running"
}

# ── Step 3: Print and open SSH ─────────────────────────────────────────────────
print_ssh_cmd() {
  section "SSH Command"
  echo ""
  echo -e "  ${BOLD}Direct SSH (public subnet, no tunnel needed):${NC}"
  echo ""
  echo -e "  ${GREEN}ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no ${SSH_USER}@${ELASTIC_IP}${NC}"
  echo ""
  echo -e "  ${BOLD}SFTP:${NC}"
  echo -e "  ${GREEN}sftp -i ${KEY_FILE} -o StrictHostKeyChecking=no ${SSH_USER}@${ELASTIC_IP}${NC}"
  echo ""
  echo -e "  ${BOLD}SSM (no key needed):${NC}"
  echo -e "  ${GREEN}aws ssm start-session --target ${INSTANCE_ID} --region ${REGION} --profile ${PROFILE}${NC}"
  echo ""
}

open_ssh() {
  section "Step 3 – Connecting via SSH"
  log "User       : ${SSH_USER}"
  log "Public IP  : ${ELASTIC_IP}"
  log "Key        : ${KEY_FILE}"
  log "Connection : Direct (public subnet)"
  echo ""
  ok  "Opening SSH session... (type 'exit' to disconnect)"
  echo ""

  ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    "${SSH_USER}@${ELASTIC_IP}"
}

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: sh ssh-connect.sh [option]

Options:
  (none)       Fetch key + connect via direct SSH (default)
  --keep-key   Reuse ~/sftp-ubuntu.pem if it already exists
  --show-cmd   Print the SSH command only (don't connect)
  --help       Show this help

Instance is in a PUBLIC subnet with a permanent Elastic IP.
SSH connects directly – no EICE tunnel or bastion required.

EOF
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  local keep_key=false show_cmd_only=false

  for arg in "$@"; do
    case "$arg" in
      --keep-key)   keep_key=true ;;
      --show-cmd)   show_cmd_only=true ;;
      --help|-h)    usage; exit 0 ;;
      *) echo -e "${RED}[ERROR]${NC} Unknown option: ${arg}"; usage; exit 1 ;;
    esac
  done

  echo ""
  echo -e "${CYAN}${BOLD}  sftp-ubuntu SSH Connect${NC}"
  echo -e "${CYAN}  Region: ${REGION}  |  Instance: ${INSTANCE_NAME}  |  User: ${SSH_USER}${NC}"
  echo ""

  command -v aws &>/dev/null \
    || die "aws cli not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

  setup_jq
  fetch_key "$keep_key"
  fetch_instance_info
  print_ssh_cmd

  if [[ "$show_cmd_only" == "true" ]]; then
    ok "Use the command above. (--show-cmd mode, not connecting)"
    exit 0
  fi

  open_ssh
}

main "$@"
