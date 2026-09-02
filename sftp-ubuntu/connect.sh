#!/usr/bin/env bash
# ==============================================================================
# connect.sh – SSH / SFTP / SSM connect helper for sftp-ubuntu EC2
#
# Usage:
#   ./connect.sh              # auto-detect best method and connect
#   ./connect.sh ssh          # SSH via EC2 Instance Connect Endpoint (EICE)
#   ./connect.sh sftp         # SFTP via EC2 Instance Connect Endpoint (EICE)
#   ./connect.sh ssm          # SSM Session Manager (portable, no admin needed)
#   ./connect.sh status       # show instance + EICE + SSM status
#   ./connect.sh get-key      # retrieve & print SSH key + ready-to-run command
#
# NO admin/sudo required – all tools downloaded as portable binaries to ~/bin/
# ==============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
INSTANCE_NAME="sftp-ubuntu"
REGION="ap-south-1"
PROFILE="CoreProdWorkloadAccount"
SECRET_ID="sftp-ubuntu/ssh-private-key"
SSH_USER="ubuntu"
KEY_FILE="${HOME}/sftp-ubuntu.pem"
VPC_ID="vpc-0c58ac931eaffb988"
# ──────────────────────────────────────────────────────────────────────────────

# Portable bin dir – no admin needed, lives entirely in home directory
PORTABLE_BIN="${HOME}/bin"
mkdir -p "$PORTABLE_BIN"
export PATH="${PORTABLE_BIN}:${PATH}"

# Global binary references (set by setup functions)
JQ_BIN="jq"
SSM_PLUGIN_BIN="session-manager-plugin"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Platform detection ────────────────────────────────────────────────────────
detect_platform() {
  OS_TYPE=$(uname -s 2>/dev/null || echo "Linux")
  ARCH=$(uname -m 2>/dev/null || echo "x86_64")
  IS_WINDOWS=false

  if echo "${OS_TYPE}" | grep -qiE "MINGW|MSYS|CYGWIN"; then
    IS_WINDOWS=true
  elif echo "${HOME}" | grep -qE '^/[a-zA-Z]/'; then
    IS_WINDOWS=true
  fi
}

# ── Download helper ───────────────────────────────────────────────────────────
download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget &>/dev/null; then
    wget -q "$url" -O "$dest"
  else
    die "Neither curl nor wget found. Cannot download ${url}"
  fi
}

# ── jq setup (portable, no admin) ────────────────────────────────────────────
setup_jq() {
  # Already available?
  if command -v jq &>/dev/null; then
    JQ_BIN="jq"; return
  fi
  if [[ -x "${PORTABLE_BIN}/jq" ]] || [[ -x "${PORTABLE_BIN}/jq.exe" ]]; then
    JQ_BIN="${PORTABLE_BIN}/jq$( [[ "$IS_WINDOWS" == "true" ]] && echo '.exe' || echo '' )"
    "$JQ_BIN" --version &>/dev/null && return
  fi

  warn "jq not found – downloading portable binary to ${PORTABLE_BIN}/ ..."

  local jq_url jq_dest
  if [[ "$IS_WINDOWS" == "true" ]]; then
    jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
    jq_dest="${PORTABLE_BIN}/jq.exe"
  else
    case "$ARCH" in
      x86_64)        jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" ;;
      aarch64|arm64) jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64" ;;
      *) die "Unsupported arch: ${ARCH}. Install jq manually: https://jqlang.github.io/jq/download/" ;;
    esac
    jq_dest="${PORTABLE_BIN}/jq"
  fi

  download "$jq_url" "$jq_dest"
  chmod +x "$jq_dest"
  JQ_BIN="$jq_dest"
  "$JQ_BIN" --version &>/dev/null || die "jq download failed. Try manually: https://jqlang.github.io/jq/download/"
  ok "jq portable binary ready: ${JQ_BIN}"
}

# ── SSM Session Manager Plugin (portable, NO admin/install needed) ────────────
setup_ssm_plugin() {
  # Check standard PATH first
  if command -v session-manager-plugin &>/dev/null; then
    SSM_PLUGIN_BIN="session-manager-plugin"; return
  fi

  # Check portable bin dir
  local portable_plugin
  if [[ "$IS_WINDOWS" == "true" ]]; then
    portable_plugin="${PORTABLE_BIN}/session-manager-plugin.exe"
    # Also check default Windows install path (if installed by someone else)
    local win_path="/c/Program Files/Amazon/SessionManagerPlugin/bin/session-manager-plugin.exe"
    if [[ -f "$win_path" ]]; then
      SSM_PLUGIN_BIN="$win_path"; return
    fi
  else
    portable_plugin="${PORTABLE_BIN}/session-manager-plugin"
  fi

  if [[ -x "$portable_plugin" ]]; then
    SSM_PLUGIN_BIN="$portable_plugin"; return
  fi

  warn "session-manager-plugin not found – downloading portable binary (no admin needed)..."

  # AWS provides a standalone binary for Windows (no installer version)
  # For Linux, extract the binary directly from the .deb package
  if [[ "$IS_WINDOWS" == "true" ]]; then
    # AWS does not publish a standalone .exe — but the installer .exe itself
    # can be run with /S (silent) flag from a writable dir if admin is available.
    # Since admin is NOT available, we use the ZIP package instead.
    local zip_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPlugin.zip"
    local zip_dest="${PORTABLE_BIN}/SessionManagerPlugin.zip"

    log "Downloading portable SSM plugin zip..."
    download "$zip_url" "$zip_dest"

    # Unzip using PowerShell (available on all Windows without admin)
    powershell.exe -NoProfile -Command \
      "Expand-Archive -Force -Path '$(cygpath -w "$zip_dest")' -DestinationPath '$(cygpath -w "$PORTABLE_BIN")'" \
      2>/dev/null || unzip -oq "$zip_dest" -d "$PORTABLE_BIN" 2>/dev/null \
      || die "Could not extract SSM plugin zip. Try: unzip ${zip_dest} -d ${PORTABLE_BIN}"

    rm -f "$zip_dest"

    # The zip extracts to bin/session-manager-plugin.exe
    local extracted
    extracted=$(find "$PORTABLE_BIN" -name "session-manager-plugin.exe" 2>/dev/null | head -1)
    if [[ -n "$extracted" ]]; then
      mv "$extracted" "${PORTABLE_BIN}/session-manager-plugin.exe" 2>/dev/null || true
      SSM_PLUGIN_BIN="${PORTABLE_BIN}/session-manager-plugin.exe"
      ok "SSM plugin portable binary ready: ${SSM_PLUGIN_BIN}"
      return
    fi
    die "Could not find session-manager-plugin.exe after extraction. Check ${PORTABLE_BIN}/"

  else
    # Linux: download and extract binary from .deb without dpkg/root
    local deb_url deb_dest
    case "$ARCH" in
      x86_64)        deb_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" ;;
      aarch64|arm64) deb_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" ;;
      *) die "Unsupported arch: ${ARCH}" ;;
    esac
    deb_dest="/tmp/session-manager-plugin.deb"
    local extract_dir="/tmp/ssm-plugin-extract"

    log "Downloading SSM plugin .deb..."
    download "$deb_url" "$deb_dest"

    mkdir -p "$extract_dir"
    # Extract .deb without dpkg (ar + tar, available everywhere)
    if command -v ar &>/dev/null; then
      ar x "$deb_dest" --output="$extract_dir" 2>/dev/null || \
        (cd "$extract_dir" && ar x "$deb_dest")
      # deb contains data.tar.xz or data.tar.gz
      local data_tar
      data_tar=$(find "$extract_dir" -name "data.tar*" | head -1)
      if [[ -n "$data_tar" ]]; then
        tar -xf "$data_tar" -C "$extract_dir" 2>/dev/null || true
      fi
    fi

    local extracted_bin
    extracted_bin=$(find "$extract_dir" -name "session-manager-plugin" -type f 2>/dev/null | head -1)

    if [[ -n "$extracted_bin" ]]; then
      cp "$extracted_bin" "${PORTABLE_BIN}/session-manager-plugin"
      chmod +x "${PORTABLE_BIN}/session-manager-plugin"
      rm -rf "$extract_dir" "$deb_dest"
      SSM_PLUGIN_BIN="${PORTABLE_BIN}/session-manager-plugin"
      ok "SSM plugin portable binary ready: ${SSM_PLUGIN_BIN}"
      return
    fi

    # Fallback: install via dpkg if available (may need root but try anyway)
    if command -v dpkg &>/dev/null; then
      dpkg -i "$deb_dest" 2>/dev/null \
        && SSM_PLUGIN_BIN="session-manager-plugin" \
        && ok "SSM plugin installed via dpkg" \
        && rm -f "$deb_dest" && return
    fi

    die "Could not extract SSM plugin binary. Please report this issue."
  fi
}

# ── AWS wrapper ───────────────────────────────────────────────────────────────
aws_cmd() {
  aws --region "$REGION" --profile "$PROFILE" "$@"
}

# ── Instance lookup helpers ───────────────────────────────────────────────────
get_instance_id() {
  local id
  id=$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null)
  [[ "$id" == "None" || -z "$id" ]] && \
    die "Instance '${INSTANCE_NAME}' not found in ${REGION}. Is it running?"
  echo "$id"
}

get_private_ip() {
  aws_cmd ec2 describe-instances \
    --instance-ids "$1" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text
}

get_instance_state() {
  aws_cmd ec2 describe-instances \
    --instance-ids "$1" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text
}

get_eice_state() {
  aws_cmd ec2 describe-instance-connect-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "InstanceConnectEndpoints[0].State" \
    --output text 2>/dev/null || echo "None"
}

get_ssm_state() {
  aws_cmd ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${1}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || echo "None"
}

# ── SSH key: retrieve, save and print decrypted ready-to-run command ──────────
get_key() {
  section "SSH Key – Secrets Manager"
  log "Secret  : ${SECRET_ID}"
  log "Saved to: ${KEY_FILE}"

  # Always remove old read-only file first to avoid chmod 400 lock
  [[ -f "$KEY_FILE" ]] && rm -f "$KEY_FILE"

  local secret
  secret=$(aws_cmd secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text) || die "Cannot retrieve secret '${SECRET_ID}'. Check IAM permissions."

  # Write plain (decrypted) PEM key – no passphrase, no encryption
  echo "$secret" | "$JQ_BIN" -r '.private_key' > "$KEY_FILE" \
    || die "Failed to parse private_key from secret JSON."

  chmod 400 "$KEY_FILE"
  ok "Key saved (chmod 400): ${KEY_FILE}"

  # ── Print the decrypted private key content directly in terminal ───────────
  local instance_id private_ip
  instance_id=$(get_instance_id)
  private_ip=$(get_private_ip "$instance_id")

  echo ""
  echo -e "${CYAN}━━━ Decrypted SSH Private Key ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}(Copy & save this as sftp-ubuntu.pem if needed on another machine)${NC}"
  echo ""
  cat "$KEY_FILE"
  echo ""
  echo -e "${CYAN}━━━ Ready-to-Run SSH Command ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}SSH (via EICE tunnel):${NC}"
  echo -e "  ${GREEN}ssh -i ${KEY_FILE} -o StrictHostKeyChecking=no \\"
  echo -e "    -o ProxyCommand=\"aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}\" \\"
  echo -e "    ${SSH_USER}@${private_ip}${NC}"
  echo ""
  echo -e "  ${BOLD}SFTP (via EICE tunnel):${NC}"
  echo -e "  ${GREEN}sftp -i ${KEY_FILE} -o StrictHostKeyChecking=no \\"
  echo -e "    -o ProxyCommand=\"aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}\" \\"
  echo -e "    ${SSH_USER}@${private_ip}${NC}"
  echo ""
  echo -e "  ${BOLD}SSM (no key needed):${NC}"
  echo -e "  ${GREEN}aws ssm start-session --target ${instance_id} --region ${REGION} --profile ${PROFILE}${NC}"
  echo ""
}

# ── SSH via EICE ──────────────────────────────────────────────────────────────
connect_ssh() {
  section "SSH via EC2 Instance Connect Endpoint"

  local instance_id private_ip eice_state
  instance_id=$(get_instance_id)
  private_ip=$(get_private_ip "$instance_id")
  eice_state=$(get_eice_state)

  log "Instance ID : ${instance_id}"
  log "Private IP  : ${private_ip}"
  log "EICE state  : ${eice_state}"

  [[ "$eice_state" == "create-complete" ]] \
    || die "EICE not ready (state: ${eice_state}). Run './connect.sh ssm' instead."

  [[ ! -f "$KEY_FILE" ]] && { warn "Key not found – retrieving..."; get_key; }

  ok "Connecting ${SSH_USER}@${private_ip} via EICE..."
  echo ""
  ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}" \
    "${SSH_USER}@${private_ip}"
}

# ── SFTP via EICE ─────────────────────────────────────────────────────────────
connect_sftp() {
  section "SFTP via EC2 Instance Connect Endpoint"

  local instance_id private_ip eice_state
  instance_id=$(get_instance_id)
  private_ip=$(get_private_ip "$instance_id")
  eice_state=$(get_eice_state)

  log "Instance ID : ${instance_id}"
  log "Private IP  : ${private_ip}"
  log "EICE state  : ${eice_state}"

  [[ "$eice_state" == "create-complete" ]] \
    || die "EICE not ready (state: ${eice_state}). Run 'terraform apply' first."

  [[ ! -f "$KEY_FILE" ]] && { warn "Key not found – retrieving..."; get_key; }

  ok "Opening SFTP ${SSH_USER}@${private_ip} via EICE..."
  echo ""
  sftp -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id ${instance_id} --region ${REGION} --profile ${PROFILE}" \
    "${SSH_USER}@${private_ip}"
}

# ── SSM Session Manager (portable plugin, no admin) ───────────────────────────
connect_ssm() {
  section "SSM Session Manager"

  setup_ssm_plugin

  # Ensure the portable binary is on PATH so aws cli can find it as a subprocess
  export PATH="${PORTABLE_BIN}:$(dirname "$SSM_PLUGIN_BIN"):${PATH}"
  ok "Using SSM plugin: ${SSM_PLUGIN_BIN}"

  local instance_id ssm_state
  instance_id=$(get_instance_id)
  ssm_state=$(get_ssm_state "$instance_id")

  log "Instance ID : ${instance_id}"
  log "SSM status  : ${ssm_state}"

  [[ "$ssm_state" == "Online" ]] \
    || warn "SSM agent status: ${ssm_state}. Trying anyway (may still be booting)..."

  ok "Starting SSM session for ${instance_id}..."
  echo ""
  aws_cmd ssm start-session --target "$instance_id"
}

# ── Auto-detect ───────────────────────────────────────────────────────────────
auto_connect() {
  section "Auto-detecting connection method"

  local instance_id eice_state ssm_state
  instance_id=$(get_instance_id)
  eice_state=$(get_eice_state)
  ssm_state=$(get_ssm_state "$instance_id")

  log "Instance ID : ${instance_id}"
  log "EICE state  : ${eice_state}"
  log "SSM status  : ${ssm_state}"

  if [[ "$ssm_state" == "Online" ]]; then
    ok "SSM Online – connecting via SSM Session Manager (no key needed)..."
    connect_ssm
  elif [[ "$eice_state" == "create-complete" ]]; then
    ok "EICE ready – connecting via SSH..."
    connect_ssh
  else
    die "No connection method available.\n  EICE: ${eice_state}  |  SSM: ${ssm_state}\n\nRun 'terraform apply' or wait 2-3 mins for the instance to boot."
  fi
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  section "Instance & Connectivity Status"

  local instance_id private_ip state eice_state ssm_state
  instance_id=$(get_instance_id)
  private_ip=$(get_private_ip "$instance_id")
  state=$(get_instance_state "$instance_id")
  eice_state=$(get_eice_state)
  ssm_state=$(get_ssm_state "$instance_id")

  echo ""
  printf "  %-25s %s\n" "Instance Name:"  "${INSTANCE_NAME}"
  printf "  %-25s %s\n" "Instance ID:"    "${instance_id}"
  printf "  %-25s %s\n" "Private IP:"     "${private_ip}"
  printf "  %-25s %s\n" "Instance State:" "${state}"
  printf "  %-25s %s\n" "EICE State:"     "${eice_state}"
  printf "  %-25s %s\n" "SSM Agent:"      "${ssm_state}"
  printf "  %-25s %s\n" "Region:"         "${REGION}"
  printf "  %-25s %s\n" "Profile:"        "${PROFILE}"
  printf "  %-25s %s\n" "Key File:"       "${KEY_FILE}"
  printf "  %-25s %s\n" "Portable Bin:"   "${PORTABLE_BIN}"
  echo ""

  echo -e "  Connection Methods:"
  if [[ "$ssm_state" == "Online" ]]; then
    echo -e "    ${GREEN}✔${NC} SSM Session Manager  → sh connect.sh ssm"
  else
    echo -e "    ${RED}✘${NC} SSM Session Manager  (agent: ${ssm_state})"
  fi
  if [[ "$eice_state" == "create-complete" ]]; then
    echo -e "    ${GREEN}✔${NC} SSH via EICE          → sh connect.sh ssh"
    echo -e "    ${GREEN}✔${NC} SFTP via EICE         → sh connect.sh sftp"
  else
    echo -e "    ${RED}✘${NC} SSH/SFTP via EICE     (state: ${eice_state})"
  fi
  echo ""
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: sh connect.sh [command]

Commands:
  (none)    Auto-detect best method (SSM preferred, then EICE)
  ssh       SSH via EC2 Instance Connect Endpoint (with key)
  sftp      SFTP via EC2 Instance Connect Endpoint (with key)
  ssm       SSM Session Manager shell (no key, no admin needed)
  status    Show instance state, EICE state, SSM agent state
  get-key   Retrieve key + print decrypted PEM + ready-to-run commands
  help      Show this help

All tools (jq, session-manager-plugin) are downloaded as portable
binaries to ~/bin/ — no admin or sudo required.

EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  detect_platform
  setup_jq

  local cmd="${1:-auto}"
  case "$cmd" in
    auto|"")       auto_connect  ;;
    ssh)           connect_ssh   ;;
    sftp)          connect_sftp  ;;
    ssm)           connect_ssm   ;;
    status)        show_status   ;;
    get-key)       get_key       ;;
    help|-h|--help) usage        ;;
    *) error "Unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"
