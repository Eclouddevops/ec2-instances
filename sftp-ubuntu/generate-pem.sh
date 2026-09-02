#!/usr/bin/env bash
# ==============================================================================
# generate-pem.sh – Retrieve SSH private key from AWS Secrets Manager
#                   and save it as sftp-ubuntu.pem
#
# Usage:
#   sh generate-pem.sh               # saves to ~/sftp-ubuntu.pem
#   sh generate-pem.sh ./mykey.pem   # saves to custom path
#
# Requirements: aws cli v2  |  jq (auto-downloaded if missing, no admin needed)
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SECRET_ID="sftp-ubuntu/ssh-private-key"
REGION="ap-south-1"
PROFILE="CoreProdWorkloadAccount"
DEFAULT_KEY_FILE="${HOME}/sftp-ubuntu.pem"
PORTABLE_BIN="${HOME}/bin"
# ──────────────────────────────────────────────────────────────────────────────

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
echo "${OS_TYPE}" | grep -qiE "MINGW|MSYS|CYGWIN" && IS_WINDOWS=true
echo "${HOME}" | grep -qE '^/[a-zA-Z]/' && IS_WINDOWS=true || true

# ── Ensure ~/bin is on PATH ───────────────────────────────────────────────────
mkdir -p "$PORTABLE_BIN"
export PATH="${PORTABLE_BIN}:${PATH}"

# ── jq setup (portable, no admin) ────────────────────────────────────────────
JQ_BIN="jq"

setup_jq() {
  command -v jq &>/dev/null && JQ_BIN="jq" && return
  [[ -x "${PORTABLE_BIN}/jq" ]]     && JQ_BIN="${PORTABLE_BIN}/jq"     && return
  [[ -x "${PORTABLE_BIN}/jq.exe" ]] && JQ_BIN="${PORTABLE_BIN}/jq.exe" && return

  warn "jq not found – downloading portable binary to ${PORTABLE_BIN}/ ..."

  local jq_url jq_dest
  if [[ "$IS_WINDOWS" == "true" ]]; then
    jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
    jq_dest="${PORTABLE_BIN}/jq.exe"
  else
    case "$ARCH" in
      x86_64)        jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" ;;
      aarch64|arm64) jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64" ;;
      *) die "Unsupported arch: ${ARCH}. Install jq: https://jqlang.github.io/jq/download/" ;;
    esac
    jq_dest="${PORTABLE_BIN}/jq"
  fi

  if command -v curl &>/dev/null; then
    curl -fsSL "$jq_url" -o "$jq_dest"
  elif command -v wget &>/dev/null; then
    wget -q "$jq_url" -O "$jq_dest"
  else
    die "curl/wget not found. Install jq manually: https://jqlang.github.io/jq/download/"
  fi

  chmod +x "$jq_dest"
  JQ_BIN="$jq_dest"
  "$JQ_BIN" --version &>/dev/null || die "jq download failed."
  ok "jq ready: ${JQ_BIN}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local key_file="${1:-$DEFAULT_KEY_FILE}"

  section "Generate PEM – sftp-ubuntu SSH Private Key"
  log "Secret ID : ${SECRET_ID}"
  log "Region    : ${REGION}"
  log "Profile   : ${PROFILE}"
  log "Output    : ${key_file}"

  # ── Dependency checks ────────────────────────────────────────────────────
  command -v aws &>/dev/null \
    || die "aws cli not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  setup_jq

  # ── Remove old key (may be chmod 400 read-only) ──────────────────────────
  if [[ -f "$key_file" ]]; then
    warn "Existing key found at ${key_file} – removing..."
    rm -f "$key_file"
  fi

  # ── Retrieve secret from Secrets Manager ────────────────────────────────
  log "Fetching secret from AWS Secrets Manager..."
  local secret
  secret=$(aws --region "$REGION" --profile "$PROFILE" \
    secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text 2>&1) \
    || die "Failed to retrieve secret.\nError: ${secret}\nCheck: aws profile, IAM permissions, region."

  # ── Extract and validate private key ────────────────────────────────────
  local private_key
  private_key=$(echo "$secret" | "$JQ_BIN" -r '.private_key' 2>/dev/null) \
    || die "Failed to parse private_key from secret JSON."

  [[ -z "$private_key" || "$private_key" == "null" ]] \
    && die "private_key field is empty in secret '${SECRET_ID}'."

  echo "$private_key" | grep -q "BEGIN.*PRIVATE KEY" \
    || die "Retrieved value does not look like a valid PEM private key."

  # ── Write PEM file ───────────────────────────────────────────────────────
  printf '%s\n' "$private_key" > "$key_file"
  chmod 400 "$key_file"
  ok "PEM file created: ${key_file} (chmod 400)"

  # ── Print key content in terminal ───────────────────────────────────────
  section "Decrypted PEM Key Content"
  echo -e "${YELLOW}(Copy the block below to use on another machine)${NC}"
  echo ""
  cat "$key_file"
  echo ""

  # ── Get instance details for ready-to-run commands ──────────────────────
  section "Ready-to-Run SSH Commands"
  local instance_id private_ip
  instance_id=$(aws --region "$REGION" --profile "$PROFILE" \
    ec2 describe-instances \
    --filters "Name=tag:Name,Values=sftp-ubuntu" \
              "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null || echo "UNKNOWN")

  private_ip=$(aws --region "$REGION" --profile "$PROFILE" \
    ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text 2>/dev/null || echo "UNKNOWN")

  echo ""
  echo -e "${BOLD}1. SSH via EC2 Instance Connect Endpoint (EICE):${NC}"
  echo -e "${GREEN}ssh -i ${key_file} \\${NC}"
  echo -e "${GREEN}  -o StrictHostKeyChecking=no \\${NC}"
  echo -e "${GREEN}  -o ProxyCommand=\"aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}\" \\${NC}"
  echo -e "${GREEN}  ubuntu@${private_ip}${NC}"
  echo ""
  echo -e "${BOLD}2. SFTP via EC2 Instance Connect Endpoint (EICE):${NC}"
  echo -e "${GREEN}sftp -i ${key_file} \\${NC}"
  echo -e "${GREEN}  -o StrictHostKeyChecking=no \\${NC}"
  echo -e "${GREEN}  -o ProxyCommand=\"aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}\" \\${NC}"
  echo -e "${GREEN}  ubuntu@${private_ip}${NC}"
  echo ""
  echo -e "${BOLD}3. SSM Session Manager (no key needed):${NC}"
  echo -e "${GREEN}aws ssm start-session \\${NC}"
  echo -e "${GREEN}  --target ${instance_id} \\${NC}"
  echo -e "${GREEN}  --region ${REGION} \\${NC}"
  echo -e "${GREEN}  --profile ${PROFILE}${NC}"
  echo ""

  section "Summary"
  printf "  %-20s %s\n" "PEM file:"       "${key_file}"
  printf "  %-20s %s\n" "Permissions:"    "400 (read-only, owner only)"
  printf "  %-20s %s\n" "Instance ID:"    "${instance_id}"
  printf "  %-20s %s\n" "Private IP:"     "${private_ip}"
  printf "  %-20s %s\n" "Secret ID:"      "${SECRET_ID}"
  printf "  %-20s %s\n" "Region:"         "${REGION}"
  echo ""
  ok "Done! Use the commands above to connect."
}

main "$@"
