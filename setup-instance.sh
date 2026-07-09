#!/usr/bin/env bash
set -euo pipefail

SOURCE_PATH="${BASH_SOURCE[0]-}"
if [[ -z "$SOURCE_PATH" || "$SOURCE_PATH" == "bash" || "$SOURCE_PATH" == "-bash" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.126.0}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-13337}"
INSTALL_RENDER_DRIVERS="${INSTALL_RENDER_DRIVERS:-1}"
INSTALL_RDP="${INSTALL_RDP:-1}"
RDP_PASSWORD="${RDP_PASSWORD:-openclaw}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
INSTALL_CODEX="${INSTALL_CODEX:-1}"
# Install the latest agent CLIs. Pin to a specific X.Y.Z here only if you need
# a reproducible version for an event.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="${HOME}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_non_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    fail "Run this script as the target user, not root. The script will use sudo only when required."
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

# Refresh the apt index at most once per run.
APT_UPDATED=0
ensure_apt_updated() {
  if [[ "$APT_UPDATED" != "1" ]]; then
    run_as_root apt-get update
    APT_UPDATED=1
  fi
}

wait_for_tcp_port() {
  local port="$1"
  local timeout_secs="${2:-30}"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi

    if (( "$(date +%s)" - start_ts >= timeout_secs )); then
      return 1
    fi

    sleep 1
  done
}

detect_deb_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

# Derive a Brev-tunnel origin for a service, falling back to a localhost URL
# when not running on a Brev instance (hostname not "brev-<id>").
derive_brev_origin() {
  local brev_prefix="$1" localhost_url="$2"
  local host_name env_id

  host_name="$(hostname 2>/dev/null || true)"
  env_id="$(printf '%s\n' "$host_name" | sed -E 's/^brev-([[:alnum:]]+)$/\1/')"

  if [[ -n "$env_id" && "$env_id" != "$host_name" ]]; then
    printf 'https://%s-%s.brevlab.com\n' "$brev_prefix" "$env_id"
  else
    printf '%s\n' "$localhost_url"
  fi
}

derive_code_server_origin() {
  derive_brev_origin "code-server0" "http://localhost:${CODE_SERVER_PORT}"
}

install_code_server() {
  local deb_arch tmp_deb url

  if command -v code-server >/dev/null 2>&1; then
    log "code-server already installed: $(code-server --version | head -n 1)"
    return
  fi

  require_cmd curl
  command -v apt-get >/dev/null 2>&1 || fail "code-server installation requires apt-get"

  deb_arch="$(detect_deb_arch)"
  tmp_deb="$(mktemp /tmp/code-server.XXXXXX.deb)"
  url="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${deb_arch}.deb"

  log "Installing code-server ${CODE_SERVER_VERSION}"
  curl -fsSL "$url" -o "$tmp_deb"
  run_as_root apt-get install -y "$tmp_deb"
  rm -f "$tmp_deb"
}

configure_code_server() {
  local config_dir settings_dir settings_user_dir workspaces_dir workspace_path home_workspace_path
  local code_server_origin

  config_dir="$TARGET_HOME/.config/code-server"
  settings_dir="$TARGET_HOME/.local/share/code-server"
  settings_user_dir="$settings_dir/User"
  workspaces_dir="$settings_user_dir/Workspaces"
  workspace_path="$workspaces_dir/openclaw-launchable.code-workspace"
  home_workspace_path="$TARGET_HOME/openclaw-launchable.code-workspace"
  code_server_origin="$(derive_code_server_origin)"

  log "Configuring code-server"
  run_as_root -u "$TARGET_USER" mkdir -p "$config_dir" "$settings_user_dir" "$workspaces_dir"

  run_as_root -u "$TARGET_USER" tee "$settings_user_dir/settings.json" >/dev/null <<EOF
{
  "workbench.startupEditor": "none",
  "window.menuBarVisibility": "classic",
  "security.workspace.trust.enabled": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "donations.disablePrompt": true,
  "extensions.ignoreRecommendations": true,
  "workbench.tips.enabled": false
}
EOF

  run_as_root -u "$TARGET_USER" tee "$config_dir/config.yaml" >/dev/null <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: none
disable-workspace-trust: true
disable-telemetry: true
disable-update-check: true
app-name: "OpenClaw Brev Launchable"
welcome-text: "Base instance ready"
EOF

  run_as_root -u "$TARGET_USER" tee "$settings_dir/coder.json" >/dev/null <<EOF
{
  "query": {
    "folder": "${TARGET_HOME}"
  },
  "lastVisited": {
    "url": "${workspace_path}",
    "workspace": true
  }
}
EOF

  run_as_root -u "$TARGET_USER" tee "$workspace_path" >/dev/null <<EOF
{
  "folders": [
    {
      "name": "Home",
      "path": "${TARGET_HOME}"
    }
  ]
}
EOF

  run_as_root -u "$TARGET_USER" install -m 644 "$workspace_path" "$home_workspace_path"

  log "code-server configured for ${code_server_origin}"
}

enable_code_server_service() {
  log "Starting code-server service"
  run_as_root systemctl daemon-reload
  run_as_root systemctl enable "code-server@${TARGET_USER}" >/dev/null
  run_as_root systemctl restart "code-server@${TARGET_USER}"

  if ! wait_for_tcp_port "$CODE_SERVER_PORT" 30; then
    run_as_root systemctl status "code-server@${TARGET_USER}" --no-pager || true
    fail "code-server did not open port ${CODE_SERVER_PORT} within 30 seconds"
  fi
}

print_configuration_pending() {
  local host_name code_server_origin

  host_name="$(hostname 2>/dev/null || true)"
  code_server_origin="$(derive_code_server_origin)"

  printf '\nBase Instance Ready\n'
  printf '===================\n\n'
  printf 'Hostname:\n%s\n\n' "${host_name:-unknown}"
  printf 'code-server:\n%s\n' "$code_server_origin"
  if [[ "$INSTALL_RDP" == "1" ]]; then
    printf '\nRDP:\n%s:3389 (user: %s)\n' "${host_name:-unknown}" "$TARGET_USER"
  fi
}

# Return success if an NVIDIA GPU is present on this instance.
gpu_available() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi
  if compgen -G "/proc/driver/nvidia/gpus/*" >/dev/null 2>&1; then
    return 0
  fi
  if command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -iq 'nvidia'; then
    return 0
  fi
  return 1
}

install_isaac_sim_render_drivers() {
  local branch version

  log "Installing NVIDIA render drivers for Isaac Sim"
  command -v apt-get >/dev/null 2>&1 || fail "Render driver install requires apt-get (Ubuntu/Debian)"
  require_cmd dpkg-query

  # Find the NVIDIA driver branch already installed by Brev (e.g. 580).
  branch="$(dpkg-query -W -f='${Package}\n' 'libnvidia-compute-*-server' 2>/dev/null \
    | sed -n 's/^libnvidia-compute-\([0-9]\+\)-server$/\1/p' | head -n1)"

  if [[ -z "$branch" ]]; then
    fail "No NVIDIA -server compute driver detected; aborting render driver install. Set INSTALL_RENDER_DRIVERS=0 to skip on non-GPU instances."
  fi

  # Pin to the exact version of the installed compute package — avoids
  # user-space / kernel-module skew that would silently break CUDA.
  version="$(dpkg-query -W -f='${Version}' "libnvidia-compute-${branch}-server")"

  log "Detected NVIDIA driver branch ${branch} (version ${version})"
  ensure_apt_updated
  run_as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
    "libnvidia-gl-${branch}-server=${version}" \
    vulkan-tools

  # Verify: the GPU must appear in vulkaninfo.
  if ! vulkaninfo --summary 2>/dev/null | grep -q "DRIVER_ID_NVIDIA_PROPRIETARY"; then
    fail "Vulkan did not enumerate the NVIDIA GPU after installing render drivers."
  fi
  log "Vulkan enumerated the NVIDIA GPU; Isaac Sim render drivers ready"
}

install_rdp() {
  log "Installing XFCE desktop + xrdp for RDP access"
  command -v apt-get >/dev/null 2>&1 || fail "RDP install requires apt-get (Ubuntu/Debian)"

  ensure_apt_updated
  run_as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y
  run_as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
    xfce4 xfce4-goodies xrdp

  run_as_root systemctl enable xrdp
  run_as_root systemctl start xrdp

  # Use the XFCE session for RDP logins.
  printf 'xfce4-session\n' | run_as_root -u "$TARGET_USER" tee "$TARGET_HOME/.xsession" >/dev/null
  run_as_root systemctl restart xrdp

  # Set the RDP login password non-interactively when provided.
  if [[ -n "$RDP_PASSWORD" ]]; then
    log "Setting RDP password for user ${TARGET_USER}"
    printf '%s:%s\n' "$TARGET_USER" "$RDP_PASSWORD" | run_as_root chpasswd
  else
    log "RDP_PASSWORD not set; set one manually with: sudo passwd ${TARGET_USER}"
  fi

  # Open the RDP port when ufw is present.
  if command -v ufw >/dev/null 2>&1; then
    run_as_root ufw allow 3389
    if run_as_root ufw status 2>/dev/null | grep -q "Status: active"; then
      run_as_root ufw reload
    fi
  fi

  log "xrdp is running on port 3389"
}

install_claude_code() {
  log "Installing Claude Code ${CLAUDE_CODE_VERSION}"
  require_cmd curl
  # The installer takes the target version (stable|latest|X.Y.Z) as its first arg.
  run_as_root -H -u "$TARGET_USER" env HOME="$TARGET_HOME" CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
    bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_CODE_VERSION"'
  log "Claude Code installed for ${TARGET_USER}"
}

install_codex() {
  log "Installing Codex ${CODEX_VERSION}"
  require_cmd curl
  # CODEX_NON_INTERACTIVE=1 skips the installer's "Start Codex now? [y/N]" tty prompt.
  # CODEX_RELEASE pins the version (latest|X.Y.Z).
  run_as_root -H -u "$TARGET_USER" env HOME="$TARGET_HOME" CODEX_NON_INTERACTIVE=1 CODEX_RELEASE="$CODEX_VERSION" \
    sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
  log "Codex installed for ${TARGET_USER}"
}

# Ensure ~/.local/bin (where claude/codex install) is on PATH for new shells,
# and for the remainder of this script's own session.
ensure_local_bin_on_path() {
  local line='export PATH="$HOME/.local/bin:$PATH"'
  local bashrc="$TARGET_HOME/.bashrc"
  local profile="$TARGET_HOME/.profile"

  log "Ensuring ~/.local/bin is on PATH for ${TARGET_USER}"

  # ~/.bashrc: PREPEND above Ubuntu's "non-interactive -> return" guard so the
  # PATH applies to login, interactive, AND non-interactive shells (appending at
  # the end only takes effect for interactive shells).
  run_as_root -u "$TARGET_USER" touch "$bashrc"
  if ! run_as_root -u "$TARGET_USER" grep -Fqx "$line" "$bashrc"; then
    run_as_root -u "$TARGET_USER" bash -c '
      f="$1"; l="$2"; tmp="$(mktemp)"
      { printf "%s\n" "$l"; cat "$f"; } > "$tmp" && cat "$tmp" > "$f"
      rm -f "$tmp"
    ' _ "$bashrc" "$line"
  fi

  # ~/.profile is read in full by login shells; appending is sufficient there.
  run_as_root -u "$TARGET_USER" touch "$profile"
  if ! run_as_root -u "$TARGET_USER" grep -Fqx "$line" "$profile"; then
    printf '\n%s\n' "$line" | run_as_root -u "$TARGET_USER" tee -a "$profile" >/dev/null
  fi

  # Make it effective in this running shell too.
  case ":$PATH:" in
    *":$TARGET_HOME/.local/bin:"*) ;;
    *) export PATH="$TARGET_HOME/.local/bin:$PATH" ;;
  esac
}

# Note how to pick up PATH changes (claude/codex/.local/bin) from this run.
# IMPORTANT: never exec an interactive shell here - this script runs during
# unattended provisioning, and replacing the process would hang the build.
reload_shell_profile() {
  log "PATH for claude/codex was added to ~/.profile and ~/.bashrc"
  log "Open a new shell or run 'source ~/.profile' to use them in an existing session"
}

main() {
  require_non_root
  require_cmd id
  require_cmd sudo

  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  fi

  log "Step 1/7: Installing and configuring code-server"
  install_code_server
  configure_code_server
  enable_code_server_service

  if [[ "$INSTALL_RENDER_DRIVERS" != "1" ]]; then
    log "Step 2/7: Skipping NVIDIA render driver install (INSTALL_RENDER_DRIVERS=0)"
  elif ! gpu_available; then
    log "Step 2/7: No NVIDIA GPU detected; skipping render driver install"
  else
    log "Step 2/7: Installing NVIDIA render drivers for Isaac Sim"
    install_isaac_sim_render_drivers
  fi

  if [[ "$INSTALL_RDP" == "1" ]]; then
    log "Step 3/7: Installing XFCE desktop + xrdp for RDP access"
    install_rdp
  else
    log "Step 3/7: Skipping RDP install (INSTALL_RDP=0)"
  fi

  if [[ "$INSTALL_CLAUDE_CODE" == "1" ]]; then
    log "Step 4/7: Installing Claude Code"
    install_claude_code
  else
    log "Step 4/7: Skipping Claude Code install (INSTALL_CLAUDE_CODE=0)"
  fi

  if [[ "$INSTALL_CODEX" == "1" ]]; then
    log "Step 5/7: Installing Codex"
    install_codex
  else
    log "Step 5/7: Skipping Codex install (INSTALL_CODEX=0)"
  fi

  if [[ "$INSTALL_CLAUDE_CODE" == "1" || "$INSTALL_CODEX" == "1" ]]; then
    ensure_local_bin_on_path
  fi

  log "Step 6/7: Base instance setup complete"
  log "Step 7/7: Printing access information"
  print_configuration_pending

  reload_shell_profile
}

main "$@"
