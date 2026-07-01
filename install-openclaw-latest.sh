#!/usr/bin/env bash
set -euo pipefail

# Install the LATEST STABLE OpenClaw using the official installer.
#
# This follows the documented official flow (https://docs.openclaw.ai/install):
#   1. Ensure a supported Node.js (24 recommended, 22.19+ required)
#   2. Install the latest stable OpenClaw via https://openclaw.ai/install.sh
#   3. Run the official `openclaw onboard` wizard (interactive)
#
# Run this in a real terminal (TTY) so onboarding can prompt you for your
# model provider and API key. Over a non-interactive shell it installs
# OpenClaw and skips onboarding (with instructions to run it yourself).
#
# Env toggles:
#   RUN_ONBOARD=0          install only, skip `openclaw onboard`
#   INSTALL_DAEMON=0       onboard without installing the persistent gateway daemon
#   NODE_SETUP_MAJOR       NodeSource series to install if Node is missing/too old (default 24)
#   AUTO_APPROVE_DEVICES=0 do NOT auto-approve browser/device pairing after install
#   AUTO_APPROVE_MINUTES   how long to auto-approve new pairings (default 20)

OPENCLAW_INSTALL_URL="${OPENCLAW_INSTALL_URL:-https://openclaw.ai/install.sh}"
NODE_MAJOR_MIN="${NODE_MAJOR_MIN:-22}"
NODE_SETUP_MAJOR="${NODE_SETUP_MAJOR:-24}"
RUN_ONBOARD="${RUN_ONBOARD:-1}"
INSTALL_DAEMON="${INSTALL_DAEMON:-1}"
# On a Brev host, allow the public tunnel origin (https://openclaw-<id>.brevlab.com)
# in the Control UI; official onboarding only allows localhost. Set 0 to skip.
ALLOW_BREV_ORIGIN="${ALLOW_BREV_ORIGIN:-1}"
# Auto-approve the first browser/device pairing(s) for a window after install, so
# participants don't hit the "device pairing required" wall. Token is still required.
AUTO_APPROVE_DEVICES="${AUTO_APPROVE_DEVICES:-1}"
AUTO_APPROVE_MINUTES="${AUTO_APPROVE_MINUTES:-20}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_non_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    fail "Run this script as the target user, not root. It will use sudo only when required."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "This step requires root privileges and sudo is not available: $*"
  fi
}

get_node_major() {
  if ! command -v node >/dev/null 2>&1; then
    printf '0\n'
    return
  fi
  node -p "process.versions.node.split('.')[0]" 2>/dev/null || printf '0\n'
}

ensure_node() {
  local major
  major="$(get_node_major)"

  if [[ "$major" -ge "$NODE_MAJOR_MIN" ]]; then
    log "Node.js $(node --version) already satisfies the >= ${NODE_MAJOR_MIN} requirement"
    return
  fi

  log "Installing Node.js ${NODE_SETUP_MAJOR} from NodeSource"
  require_cmd curl
  command -v apt-get >/dev/null 2>&1 || fail "This script currently supports Ubuntu/Debian environments with apt-get"

  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_SETUP_MAJOR}.x" | run_as_root bash -
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

  log "Installed Node.js $(node --version)"
}

_prepend_path() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || return 0
  case ":$PATH:" in
    *":$d:"*) ;;
    *) export PATH="$d:$PATH" ;;
  esac
}

# The official installer puts openclaw in the npm user prefix (default
# ~/.npm-global/bin) and persists PATH only to ~/.bashrc / ~/.zshrc, which this
# running shell has not sourced. Make openclaw resolvable for the current run.
ensure_openclaw_on_path() {
  local prefix
  _prepend_path "$HOME/.npm-global/bin"
  _prepend_path "$HOME/.local/bin"
  if command -v npm >/dev/null 2>&1; then
    prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$prefix" && "$prefix" != "undefined" && "$prefix" != "null" ]]; then
      _prepend_path "$prefix/bin"
    fi
  fi
}

install_openclaw() {
  require_cmd curl
  log "Installing latest stable OpenClaw via the official installer (${OPENCLAW_INSTALL_URL})"
  # --no-onboard: install only; we run onboarding explicitly below so it is
  # not silently skipped or double-run.
  curl -fsSL "$OPENCLAW_INSTALL_URL" | bash -s -- --no-onboard

  ensure_openclaw_on_path
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw installed but 'openclaw' is not on PATH (looked in ~/.npm-global/bin, ~/.local/bin, npm prefix). Open a new shell and re-run."
  log "Installed OpenClaw $(openclaw --version 2>/dev/null || echo '(version unknown)')"
}

onboard_openclaw() {
  local args
  args=(onboard)
  [[ "$INSTALL_DAEMON" == "1" ]] && args+=(--install-daemon)

  if [[ ! -t 0 ]]; then
    log "Non-interactive shell detected; skipping 'openclaw onboard'."
    log "Run it yourself in a terminal:  openclaw ${args[*]}"
    return
  fi

  log "Running official onboarding: openclaw ${args[*]}"
  openclaw "${args[@]}"
}

# On Brev, the Control UI is reached via https://openclaw-<id>.brevlab.com, which
# the stock onboarding does not allow-list. Append it (idempotently) and restart.
allow_brev_origin() {
  local h id origin
  h="$(hostname 2>/dev/null || true)"
  id="${h#brev-}"
  if [[ -z "$id" || "$id" == "$h" ]]; then
    log "Not a Brev host (hostname=${h:-unknown}); skipping Brev origin allow-list"
    return
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    log "openclaw not on PATH; skipping Brev origin allow-list"
    return
  fi

  origin="https://openclaw-${id}.brevlab.com"
  log "Allowing Brev Control UI origin: $origin"
  # Use the CLI so it writes the correct config file and coordinates with the
  # gateway. This overwrites allowedOrigins with localhost + the Brev origin
  # (the localhost entries match what onboarding sets).
  if ! openclaw config set gateway.controlUi.allowedOrigins \
      "[\"http://127.0.0.1:18789\",\"http://localhost:18789\",\"$origin\"]" --strict-json; then
    log "Failed to set allowedOrigins; add '$origin' to gateway.controlUi.allowedOrigins manually"
    return
  fi

  # Apply by restarting the gateway (best effort; daemon or manual).
  openclaw gateway restart >/dev/null 2>&1 \
    || log "Restart the gateway to apply the new origin (e.g. 'openclaw gateway restart')"
}

# Each browser needs a one-time pairing approval from the Gateway host. Onboarding
# does not auto-approve, so the first dashboard visit shows "device pairing required".
# Launch a short-lived background loop that approves incoming pairings, so the
# participant's first connection is approved automatically. Token auth still applies.
auto_approve_devices() {
  local oc helper logf
  if ! command -v openclaw >/dev/null 2>&1; then
    log "openclaw not on PATH; skipping device auto-approve"
    return
  fi
  oc="$(command -v openclaw)"
  helper="$HOME/.openclaw/auto-approve-loop.sh"
  logf="$HOME/.openclaw/auto-approve.log"
  mkdir -p "$HOME/.openclaw"

  cat > "$helper" <<'HLP'
#!/usr/bin/env bash
# Approve any pending device pairings until the deadline. Args: <openclaw-bin> <minutes>
OC="$1"; MINUTES="$2"
end=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  n="$("$OC" devices list --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String((j.pending||[]).length))}catch(e){process.stdout.write("0")}})' 2>/dev/null)"
  [ -z "$n" ] && n=0
  if [ "$n" -gt 0 ] 2>/dev/null; then
    "$OC" devices approve --latest >/dev/null 2>&1 || true
  fi
  sleep 3
done
HLP
  chmod +x "$helper"

  log "Auto-approving new device pairings for ${AUTO_APPROVE_MINUTES} min — open the dashboard within this window."
  log "  (disable with AUTO_APPROVE_DEVICES=0; manual approve: 'openclaw devices approve --latest')"
  # setsid so the loop survives this shell exiting.
  setsid bash "$helper" "$oc" "$AUTO_APPROVE_MINUTES" >"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# Print the Control UI URL (Brev tunnel when on Brev, else localhost) and the token.
print_dashboard_info() {
  local h id origin token dash url
  if ! command -v openclaw >/dev/null 2>&1; then
    log "openclaw not on PATH; cannot print dashboard info"
    return
  fi

  h="$(hostname 2>/dev/null || true)"
  id="${h#brev-}"
  if [[ -n "$id" && "$id" != "$h" ]]; then
    origin="https://openclaw-${id}.brevlab.com"
  else
    origin="http://127.0.0.1:18789"
  fi

  # Prefer the token from the dashboard URL; fall back to config.
  dash="$(openclaw dashboard --no-open 2>/dev/null || true)"
  token="$(printf '%s\n' "$dash" | sed -nE 's#.*[#?]token=([A-Za-z0-9]+).*#\1#p' | head -n1)"
  if [[ -z "$token" ]]; then
    token="$(openclaw config get gateway.auth.token 2>/dev/null | tr -d '"' | head -n1)"
  fi

  if [[ -n "$token" && "$token" != "__OPENCLAW_REDACTED__" && "$token" != "null" ]]; then
    url="${origin}/#token=${token}"
  else
    url="${origin}/"
    token="(unavailable — run: openclaw config get gateway.auth.token)"
  fi

  printf '\n'
  printf '================ OpenClaw Control UI ================\n'
  printf '  Open in your browser:\n'
  printf '    %s\n\n' "$url"
  printf '  Dashboard URL: %s\n' "$origin"
  printf '  Token:         %s\n' "$token"
  printf '====================================================\n'
}

main() {
  require_non_root
  require_cmd curl

  log "Step 1/3: Ensuring Node.js"
  ensure_node

  log "Step 2/3: Installing latest stable OpenClaw"
  install_openclaw

  log "Step 3/3: Onboarding"
  if [[ "$RUN_ONBOARD" == "1" ]]; then
    onboard_openclaw
  else
    log "Skipping onboarding (RUN_ONBOARD=0). Run later:  openclaw onboard --install-daemon"
  fi

  if [[ "$ALLOW_BREV_ORIGIN" == "1" ]]; then
    allow_brev_origin
  fi

  if [[ "$AUTO_APPROVE_DEVICES" == "1" ]]; then
    auto_approve_devices
  fi

  log "Done. If 'openclaw' is not found, run 'source ~/.profile' or open a new shell."

  print_dashboard_info
}

main "$@"
