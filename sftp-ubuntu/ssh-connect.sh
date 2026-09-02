#!/usr/bin/env bash
# ==============================================================================
# ssh-connect.sh – Connect to sftp-ubuntu EC2 via SSH
#
# This script does everything in one shot:
#   1. Fetches the SSH private key from AWS Secrets Manager
#   2. Saves it as ~/sftp-ubuntu.pem  (chmod 400)
#   3. Looks up the instance's private IP automatically
#   4. Opens SSH via EC2 Instance Connect Endpoint (EICE) tunnel
#      – no public IP, no bastion, no VPN needed
#
# Usage:
#   sh ssh-connect.sh            # connect (auto-fetch key every time)
#   sh ssh-connect.sh --keep-key # reuse existing ~/sftp-ubuntu.pem if present
#   sh ssh-connect.sh --show-cmd # print the ssh command only, don't connect
# ==============================================================================

set -euo pipefail

# ── Configuration (edit these if needed) ──────────────────────────────────────
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

# ── Platform detection ────────────────────────────────────────────────────────
OS_TYPE=$(uname -s 2>/dev/null || echo "Linux")
ARCH=$(uname -m 2>/dev/null || echo "x86_64")
IS_WINDOWS=false
echo "${OS_TYPE}" | grep -qiE "MINGW|MSYS|CYGWIN" && IS_WINDOWS=true || true
echo "${HOME}" | grep -qE '^/[a-zA-Z]/' && IS_WINDOWS=true || true

# ── jq: portable, no admin ────────────────────────────────────────────────────
JQ_BIN="jq"
setup_jq() {
  command -v jq &>/dev/null      && JQ_BIN="jq"                        && return
  [[ -x "${PORTABLE_BIN}/jq" ]]     && JQ_BIN="${PORTABLE_BIN}/jq"     && return
  [[ -x "${PORTABLE_BIN}/jq.exe" ]] && JQ_BIN="${PORTABLE_BIN}/jq.exe" && return

  warn "jq not found – downloading portable binary to ${PORTABLE_BIN}/ ..."
  local url dest
  if [[ "$IS_WINDOWS" == "true" ]]; then
    url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
    dest="${PORTABLE_BIN}/jq.exe"
  else
    case "$ARCH" in
      x86_64)        url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" ;;
      aarch64|arm64) url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64" ;;
      *) die "Unsupported arch ${ARCH}. Install jq: https://jqlang.github.io/jq/download/" ;;
    esac
    dest="${PORTABLE_BIN}/jq"
  fi
  _download "$url" "$dest"
  chmod +x "$dest"
  JQ_BIN="$dest"
  "$JQ_BIN" --version &>/dev/null || die "jq setup failed."
  ok "jq ready: ${JQ_BIN}"
}

# ── Download helper ───────────────────────────────────────────────────────────
_download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget &>/dev/null; then
    wget -q "$url" -O "$dest"
  else
    die "curl/wget not found. Cannot download ${url}"
  fi
}

# ── AWS wrapper ───────────────────────────────────────────────────────────────
aws_cmd() { aws --region "$REGION" --profile "$PROFILE" "$@"; }

# ── Step 1: Retrieve SSH key from Secrets Manager ─────────────────────────────
fetch_key() {
  local keep_existing="${1:-false}"

  if [[ "$keep_existing" == "true" && -f "$KEY_FILE" ]]; then
    ok "Reusing existing key: ${KEY_FILE}"
    return
  fi

  section "Step 1 – Fetching SSH Key from Secrets Manager"
  log "Secret  : ${SECRET_ID}"
  log "Key file: ${KEY_FILE}"

  # Remove old read-only key to avoid 'Permission denied' on overwrite
  [[ -f "$KEY_FILE" ]] && { warn "Removing old key..."; rm -f "$KEY_FILE"; }

  local secret
  secret=$(aws_cmd secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>&1) \
    || die "Cannot retrieve secret.\nError: ${secret}\nCheck: aws profile, IAM permissions, region."

  local private_key
  private_key=$(echo "$secret" | "$JQ_BIN" -r '.private_key' 2>/dev/null) \
    || die "Failed to parse private_key from secret JSON."

  [[ -z "$private_key" || "$private_key" == "null" ]] \
    && die "private_key is empty in secret '${SECRET_ID}'."

  echo "$private_key" | grep -q "BEGIN.*PRIVATE KEY" \
    || die "Value does not look like a valid PEM private key."

  printf '%s\n' "$private_key" > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ok "Key saved: ${KEY_FILE} (chmod 400)"
}

# ── Step 2: Look up instance ID and private IP ────────────────────────────────
fetch_instance_info() {
  section "Step 2 – Looking Up Instance"

  INSTANCE_ID=$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null)

  [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]] \
    && die "Instance '${INSTANCE_NAME}' not found or not running in ${REGION}."

  PRIVATE_IP=$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text 2>/dev/null)

  INSTANCE_STATE=$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text 2>/dev/null)

  log "Instance ID : ${INSTANCE_ID}"
  log "Private IP  : ${PRIVATE_IP}"
  log "State       : ${INSTANCE_STATE}"
  ok "Instance found and running"
}

# ── Step 3: Check EICE is ready ───────────────────────────────────────────────
check_eice() {
  section "Step 3 – Checking EC2 Instance Connect Endpoint"

  EICE_STATE=$(aws_cmd ec2 describe-instance-connect-endpoints \
    --filters "Name=vpc-id,Values=vpc-0c58ac931eaffb988" \
    --query "InstanceConnectEndpoints[0].State" \
    --output text 2>/dev/null || echo "None")

  EICE_ID=$(aws_cmd ec2 describe-instance-connect-endpoints \
    --filters "Name=vpc-id,Values=vpc-0c58ac931eaffb988" \
    --query "InstanceConnectEndpoints[0].InstanceConnectEndpointId" \
    --output text 2>/dev/null || echo "None")

  log "EICE ID    : ${EICE_ID}"
  log "EICE State : ${EICE_STATE}"

  if [[ "$EICE_STATE" != "create-complete" ]]; then
    warn "EICE not ready (state: ${EICE_STATE})"
    warn "Run 'terraform apply' to create it, or try SSM:"
    warn "  aws ssm start-session --target ${INSTANCE_ID} --region ${REGION} --profile ${PROFILE}"
    die "Cannot connect via SSH without EICE."
  fi
  ok "EICE is ready"
}

# ── Step 4: Build and display the SSH command ─────────────────────────────────
build_ssh_cmd() {
  SSH_CMD="ssh -i ${KEY_FILE} \
  -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o ProxyCommand=\"aws ec2-instance-connect open-tunnel \
    --instance-id ${INSTANCE_ID} \
    --region ${REGION} \
    --profile ${PROFILE}\" \
  ${SSH_USER}@${PRIVATE_IP}"
}

print_ssh_cmd() {
  section "SSH Command"
  echo ""
  echo -e "${BOLD}Copy-paste command:${NC}"
  echo ""
  echo -e "${GREEN}ssh -i ${KEY_FILE} \\${NC}"
  echo -e "${GREEN}  -o StrictHostKeyChecking=no \\${NC}"
  echo -e "${GREEN}  -o ServerAliveInterval=60 \\${NC}"
  echo -e "${GREEN}  -o ServerAliveCountMax=3 \\${NC}"
  echo -e "${GREEN}  -o ProxyCommand=\"aws ec2-instance-connect open-tunnel --instance-id ${INSTANCE_ID} --region ${REGION} --profile ${PROFILE}\" \\${NC}"
  echo -e "${GREEN}  ${SSH_USER}@${PRIVATE_IP}${NC}"
  echo ""
}

# ── Step 5: Open SSH session ──────────────────────────────────────────────────
open_ssh() {
  section "Step 4 – Connecting via SSH"
  log "User       : ${SSH_USER}"
  log "Host       : ${PRIVATE_IP}"
  log "Key        : ${KEY_FILE}"
  log "Tunnel     : EICE (${EICE_ID})"
  echo ""
  ok "Opening SSH session... (type 'exit' to disconnect)"
  echo ""

  ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel \
      --instance-id ${INSTANCE_ID} \
      --region ${REGION} \
      --profile ${PROFILE}" \
    "${SSH_USER}@${PRIVATE_IP}"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: sh ssh-connect.sh [option]

Options:
  (none)       Fetch key + connect via SSH (default)
  --keep-key   Reuse ~/sftp-ubuntu.pem if it already exists
  --show-cmd   Print the SSH command only (don't connect)
  --help       Show this help

Examples:
  sh ssh-connect.sh              # fresh key fetch + SSH connect
  sh ssh-connect.sh --keep-key   # skip key fetch if pem exists
  sh ssh-connect.sh --show-cmd   # just print the ssh command

EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local keep_key=false
  local show_cmd_only=false

  for arg in "$@"; do
    case "$arg" in
      --keep-key)  keep_key=true ;;
      --show-cmd)  show_cmd_only=true ;;
      --help|-h)   usage; exit 0 ;;
      *) echo -e "${RED}[ERROR]${NC} Unknown option: ${arg}"; usage; exit 1 ;;
    esac
  done

  echo ""
  echo -e "${CYAN}${BOLD}  sftp-ubuntu SSH Connect${NC}"
  echo -e "${CYAN}  Region: ${REGION}  |  Instance: ${INSTANCE_NAME}  |  User: ${SSH_USER}${NC}"
  echo ""

  # Check aws cli
  command -v aws &>/dev/null \
    || die "aws cli not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

  setup_jq
  fetch_key "$keep_key"
  fetch_instance_info
  check_eice
  build_ssh_cmd
  print_ssh_cmd

  if [[ "$show_cmd_only" == "true" ]]; then
    ok "Use the command above to connect. (--show-cmd mode, not connecting)"
    exit 0
  fi

  open_ssh
}

main "$@"
