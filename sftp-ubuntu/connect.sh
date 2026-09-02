#!/usr/bin/env bash
# ==============================================================================
# connect.sh – SSH / SFTP / SSM connect helper for sftp-ubuntu EC2
#
# Usage:
#   ./connect.sh              # auto-detect best method and connect
#   ./connect.sh ssh          # SSH via EC2 Instance Connect Endpoint (EICE)
#   ./connect.sh sftp         # SFTP via EC2 Instance Connect Endpoint (EICE)
#   ./connect.sh ssm          # SSM Session Manager (no key needed)
#   ./connect.sh status       # show instance + EICE + SSM endpoint status
#   ./connect.sh get-key      # retrieve SSH key from Secrets Manager only
#
# Requirements:
#   - aws cli v2
#   - jq
#   - ssh / sftp (for ssh/sftp modes)
#   - aws session-manager-plugin (for ssm mode)
#     Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
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

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v aws  &>/dev/null || missing+=("aws cli")
  command -v jq   &>/dev/null || missing+=("jq")
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}

# ── AWS helpers ───────────────────────────────────────────────────────────────
aws_cmd() {
  aws --region "$REGION" --profile "$PROFILE" "$@"
}

get_instance_id() {
  local id
  id=$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=running,stopped,pending" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null)
  [[ "$id" == "None" || -z "$id" ]] && die "Instance '${INSTANCE_NAME}' not found in ${REGION}. Is it running?"
  echo "$id"
}

get_private_ip() {
  local instance_id="$1"
  aws_cmd ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text
}

get_instance_state() {
  local instance_id="$1"
  aws_cmd ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text
}

get_eice_state() {
  aws_cmd ec2 describe-instance-connect-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "InstanceConnectEndpoints[0].State" \
    --output text 2>/dev/null || echo "none"
}

get_ssm_state() {
  local instance_id="$1"
  aws_cmd ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || echo "none"
}

# ── Retrieve SSH key from Secrets Manager ─────────────────────────────────────
get_key() {
  section "Retrieving SSH Key from Secrets Manager"
  log "Secret ID : ${SECRET_ID}"
  log "Key file  : ${KEY_FILE}"

  # Remove old read-only copy if it exists
  [[ -f "$KEY_FILE" ]] && { log "Removing old key file..."; rm -f "$KEY_FILE"; }

  local secret
  secret=$(aws_cmd secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text) || die "Failed to retrieve secret '${SECRET_ID}'. Check permissions."

  echo "$secret" | jq -r '.private_key' > "$KEY_FILE" \
    || die "Failed to parse private_key from secret. Is jq installed?"

  chmod 400 "$KEY_FILE"
  ok "Key saved to ${KEY_FILE} (chmod 400)"
}

# ── SSH via EC2 Instance Connect Endpoint ─────────────────────────────────────
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
    || die "EICE is not ready (state: ${eice_state}). Run 'terraform apply' or use './connect.sh ssm' instead."

  # Fetch key if missing or not read-only
  if [[ ! -f "$KEY_FILE" ]]; then
    warn "Key file not found. Retrieving from Secrets Manager..."
    get_key
  fi

  ok "Connecting to ${SSH_USER}@${private_ip} via EICE tunnel..."
  echo ""

  ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel \
      --instance-id ${instance_id} \
      --region ${REGION} \
      --profile ${PROFILE}" \
    "${SSH_USER}@${private_ip}"
}

# ── SFTP via EC2 Instance Connect Endpoint ────────────────────────────────────
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
    || die "EICE is not ready (state: ${eice_state}). Run 'terraform apply' first."

  if [[ ! -f "$KEY_FILE" ]]; then
    warn "Key file not found. Retrieving from Secrets Manager..."
    get_key
  fi

  ok "Opening SFTP to ${SSH_USER}@${private_ip} via EICE tunnel..."
  echo ""

  sftp -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ProxyCommand="aws ec2-instance-connect open-tunnel \
      --instance-id ${instance_id} \
      --region ${REGION} \
      --profile ${PROFILE}" \
    "${SSH_USER}@${private_ip}"
}

# ── SSM Session Manager ───────────────────────────────────────────────────────
connect_ssm() {
  section "SSM Session Manager"

  command -v session-manager-plugin &>/dev/null \
    || warn "session-manager-plugin not found. Install it: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

  local instance_id ssm_state
  instance_id=$(get_instance_id)
  ssm_state=$(get_ssm_state "$instance_id")

  log "Instance ID : ${instance_id}"
  log "SSM status  : ${ssm_state}"

  [[ "$ssm_state" == "Online" ]] \
    || { warn "SSM agent status: ${ssm_state}. Instance may still be booting. Attempting connection anyway..."; }

  ok "Starting SSM session for ${instance_id}..."
  echo ""

  aws_cmd ssm start-session --target "$instance_id"
}

# ── Auto-detect best method ───────────────────────────────────────────────────
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
    ok "SSM agent is Online. Connecting via SSM Session Manager..."
    connect_ssm
  elif [[ "$eice_state" == "create-complete" ]]; then
    ok "EICE is ready. Connecting via EC2 Instance Connect Endpoint..."
    connect_ssh
  else
    die "No connection method available.\n  EICE state : ${eice_state}\n  SSM status : ${ssm_state}\n\nFix options:\n  1. Run 'terraform apply' to create EICE + SSM endpoints\n  2. Wait 2-3 mins for instance to boot and SSM agent to register"
  fi
}

# ── Status overview ───────────────────────────────────────────────────────────
show_status() {
  section "Instance & Connectivity Status"

  local instance_id private_ip state eice_state ssm_state
  instance_id=$(get_instance_id)
  private_ip=$(get_private_ip "$instance_id")
  state=$(get_instance_state "$instance_id")
  eice_state=$(get_eice_state)
  ssm_state=$(get_ssm_state "$instance_id")

  echo ""
  printf "  %-25s %s\n" "Instance Name:"   "${INSTANCE_NAME}"
  printf "  %-25s %s\n" "Instance ID:"     "${instance_id}"
  printf "  %-25s %s\n" "Private IP:"      "${private_ip}"
  printf "  %-25s %s\n" "Instance State:"  "${state}"
  printf "  %-25s %s\n" "EICE State:"      "${eice_state}"
  printf "  %-25s %s\n" "SSM Agent:"       "${ssm_state}"
  printf "  %-25s %s\n" "Region:"          "${REGION}"
  printf "  %-25s %s\n" "Profile:"         "${PROFILE}"
  printf "  %-25s %s\n" "Key File:"        "${KEY_FILE}"
  echo ""

  # Connectivity summary
  echo -e "  Connection Methods:"
  if [[ "$ssm_state" == "Online" ]]; then
    echo -e "    ${GREEN}✔${NC} SSM Session Manager  → ./connect.sh ssm"
  else
    echo -e "    ${RED}✘${NC} SSM Session Manager  (agent: ${ssm_state})"
  fi

  if [[ "$eice_state" == "create-complete" ]]; then
    echo -e "    ${GREEN}✔${NC} SSH via EICE          → ./connect.sh ssh"
    echo -e "    ${GREEN}✔${NC} SFTP via EICE         → ./connect.sh sftp"
  else
    echo -e "    ${RED}✘${NC} SSH/SFTP via EICE     (EICE state: ${eice_state})"
  fi
  echo ""
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: $(basename "$0") [command]

Commands:
  (none)      Auto-detect best method and connect (SSM preferred)
  ssh         SSH into the instance via EC2 Instance Connect Endpoint
  sftp        SFTP into the instance via EC2 Instance Connect Endpoint
  ssm         Open a shell via SSM Session Manager (no SSH key needed)
  status      Show instance state, EICE state, SSM agent status
  get-key     Retrieve the SSH private key from Secrets Manager only
  help        Show this help message

Examples:
  ./connect.sh             # auto-connect
  ./connect.sh ssh         # SSH with key via EICE
  ./connect.sh sftp        # SFTP with key via EICE
  ./connect.sh ssm         # SSM shell (no key)
  ./connect.sh status      # check what's available
  ./connect.sh get-key     # download key to ~/sftp-ubuntu.pem

EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_deps

  local cmd="${1:-auto}"

  case "$cmd" in
    auto|"")  auto_connect  ;;
    ssh)      connect_ssh   ;;
    sftp)     connect_sftp  ;;
    ssm)      connect_ssm   ;;
    status)   show_status   ;;
    get-key)  get_key       ;;
    help|-h|--help) usage   ;;
    *) error "Unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"
