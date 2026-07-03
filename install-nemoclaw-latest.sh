#!/usr/bin/env bash
set -euo pipefail

# Install NemoClaw (NVIDIA's sandboxed OpenClaw) using the official installer.
#
# Docs: https://docs.nvidia.com/nemoclaw/user-guide/openclaw/get-started/quickstart
#
# NemoClaw runs OpenClaw inside a sandboxed OpenShell runtime (Docker). The
# official bootstrap installs Node.js if needed, then runs `nemoclaw onboard` to
# create a sandbox, configure inference, and apply security/network policies.
#
# By default this installs NemoClaw with preset settings (NVIDIA provider, the
# default sandbox, web-search & messaging channels skipped) and ONLY asks you
# for your NVIDIA API key. Run it in a real terminal so it can prompt, or set
# NVIDIA_INFERENCE_API_KEY in the environment for a fully hands-off install.
#
# Note: NemoClaw's non-interactive mode only controls provider/key/sandbox. The
# OpenClaw-onboarding options from the OpenClaw guide (hooks, skills, systemd
# lingering, gateway runtime, hatch) have no NemoClaw equivalent here and are
# managed by NemoClaw's own sandbox lifecycle.
#
# Env toggles:
#   NVIDIA_INFERENCE_API_KEY    your nvapi-... key (build.nvidia.com); if set, no prompt
#   NEMOCLAW_POLICY_MODE        enforce (default) | advisory — enforce actively BLOCKS
#                               unlisted traffic (required for the hands-on deny-by-default
#                               demo). advisory only logs; nothing is denied.
#   NEMOCLAW_POLICY_TIER        restricted (default) | balanced | open — starting preset
#                               posture. restricted = inference + core tooling only; open
#                               doors later with `nemoclaw <sandbox> policy-add`.
#   SANDBOX_NAME                sandbox name (default: my-assistant)
#   NEMOCLAW_PROVIDER           inference provider (default: build = NVIDIA endpoints)
#   ACCEPT_THIRD_PARTY=0        do NOT auto-accept third-party software (installer will prompt)
#   FULL_WIZARD=1               run NemoClaw's full interactive wizard instead of presets
#   ALLOW_BREV_ORIGIN=0         do NOT auto-allow the Brev tunnel origin for the Control UI
#   CHAT_UI_URL                 explicit Control UI origin (default on Brev: https://openclaw-<id>.brevlab.com)
#   INSTALL_DOCS_MCP=0          do NOT register the NemoClaw docs MCP server with Claude Code
#   NEMOCLAW_INSTALL_URL        override installer URL (default: https://www.nvidia.com/nemoclaw.sh)
#   NEMOCLAW_INSTALL_REF        pinned Git ref/SHA to install (default: frozen lkg SHA)
#   NEMOCLAW_INSTALL_TAG        Git tag to install instead (e.g. lkg, v0.0.72)

NEMOCLAW_INSTALL_URL="${NEMOCLAW_INSTALL_URL:-https://www.nvidia.com/nemoclaw.sh}"
# Pin NemoClaw to a known-good Git ref for the hackathon. The upstream default
# 'lkg' is a MOVING pointer, so we freeze to the exact SHA it resolved to on
# 2026-07-02 (tag 'lkg' -> e4b9111). Override with NEMOCLAW_INSTALL_REF (exact
# ref/SHA) or NEMOCLAW_INSTALL_TAG (e.g. lkg, v0.0.72).
NEMOCLAW_INSTALL_REF="${NEMOCLAW_INSTALL_REF:-e4b9111f5f0535c2fc3d6fbe8dc8dca101a6fdce}"
ACCEPT_THIRD_PARTY="${ACCEPT_THIRD_PARTY:-1}"
FULL_WIZARD="${FULL_WIZARD:-0}"
NEMOCLAW_PROVIDER="${NEMOCLAW_PROVIDER:-build}"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
# Hands-on session posture: start strict (deny-by-default actively enforced,
# minimal presets) and open scoped doors during the session. Override either to
# relax. See 06_nemoclaw-hands-on-session.md, Module 4.
NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-enforce}"
NEMOCLAW_POLICY_TIER="${NEMOCLAW_POLICY_TIER:-restricted}"
# On a Brev host, tell the sandbox to allow the public tunnel origin for the
# Control UI. The sandbox derives gateway.controlUi.allowedOrigins from
# CHAT_UI_URL at build time, so this must be set BEFORE the sandbox is built.
ALLOW_BREV_ORIGIN="${ALLOW_BREV_ORIGIN:-1}"
CHAT_UI_URL="${CHAT_UI_URL:-}"
# Register the NemoClaw + OpenShell docs MCP servers with Claude Code / Codex (if
# installed), so the agent can look up NemoClaw and OpenShell docs.
# https://docs.nvidia.com/nemoclaw/.../agent-skills
INSTALL_DOCS_MCP="${INSTALL_DOCS_MCP:-1}"
DOCS_MCP_URL="${DOCS_MCP_URL:-https://docs.nvidia.com/nemoclaw/_mcp/server}"
OPENSHELL_DOCS_MCP_URL="${OPENSHELL_DOCS_MCP_URL:-https://docs.nvidia.com/openshell/_mcp/server}"

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

_prepend_path() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || return 0
  case ":$PATH:" in
    *":$d:"*) ;;
    *) export PATH="$d:$PATH" ;;
  esac
}

# The installer puts nemoclaw in the npm user prefix (default ~/.npm-global/bin)
# and persists PATH only to shell rc files this running shell has not sourced.
ensure_nemoclaw_on_path() {
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

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is required for NemoClaw (it runs the sandbox in Docker). Install Docker and retry."
  fi
  if ! docker info >/dev/null 2>&1; then
    log "WARNING: cannot talk to the Docker daemon as $(id -un)."
    log "  You may need to join the docker group:  sudo usermod -aG docker \$USER  (then re-login)"
    log "  Continuing; the installer may re-attempt with sudo."
  fi
}

# Ask only for the NVIDIA API key (everything else is preset). Skipped when the
# key is already in the environment.
prompt_for_key() {
  if [[ -n "${NVIDIA_INFERENCE_API_KEY:-}" ]]; then
    log "Using NVIDIA API key from the environment"
    return
  fi
  if [[ ! -t 0 ]]; then
    fail "No API key and no terminal. Set NVIDIA_INFERENCE_API_KEY=nvapi-... or run this in 'brev shell'."
  fi

  printf '\nNemoClaw will be installed with these preset settings:\n'
  printf '  Provider:        NVIDIA (%s)\n' "$NEMOCLAW_PROVIDER"
  printf '  Sandbox name:    %s\n' "$SANDBOX_NAME"
  printf '  Policy mode:     %s\n' "$NEMOCLAW_POLICY_MODE"
  printf '  Policy tier:     %s\n' "$NEMOCLAW_POLICY_TIER"
  printf '  Web search:      skipped\n'
  printf '  Msg channels:    skipped\n'
  printf '  (override with FULL_WIZARD=1 to choose everything yourself)\n\n'

  local key
  read -r -s -p "Enter NVIDIA API Key (nvapi-...): " key
  printf '\n'
  [[ -n "$key" ]] || fail "A non-empty NVIDIA API key is required."
  case "$key" in
    nvapi-*) ;;
    sk-*) fail "That's an 'sk-' key from inference.nvidia.com. NemoClaw needs an 'nvapi-' key from build.nvidia.com/settings/api-keys." ;;
    *) log "WARNING: key does not start with 'nvapi-'; continuing anyway." ;;
  esac
  export NVIDIA_INFERENCE_API_KEY="$key"
}

# Derive the Brev tunnel origin (https://openclaw-<id>.brevlab.com) from the
# hostname, so the sandbox is built allowing browser access over the tunnel.
resolve_chat_ui_url() {
  if [[ -n "$CHAT_UI_URL" ]]; then
    return
  fi
  [[ "$ALLOW_BREV_ORIGIN" == "1" ]] || return
  local h id
  h="$(hostname 2>/dev/null || true)"
  id="${h#brev-}"
  if [[ -n "$id" && "$id" != "$h" ]]; then
    CHAT_UI_URL="https://openclaw-${id}.brevlab.com"
    log "Brev host detected — sandbox Control UI origin: $CHAT_UI_URL"
  fi
}

install_nemoclaw() {
  require_cmd curl
  local envs=()

  # Freeze the installed ref so a moving 'lkg' can't change the build mid-event.
  [[ -n "${NEMOCLAW_INSTALL_REF:-}" ]] && envs+=("NEMOCLAW_INSTALL_REF=${NEMOCLAW_INSTALL_REF}")

  [[ "$ACCEPT_THIRD_PARTY" == "1" ]] && envs+=("NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1")

  # Security posture (applies to both preset and wizard paths).
  [[ -n "$NEMOCLAW_POLICY_MODE" ]] && envs+=("NEMOCLAW_POLICY_MODE=${NEMOCLAW_POLICY_MODE}")
  [[ -n "$NEMOCLAW_POLICY_TIER" ]] && envs+=("NEMOCLAW_POLICY_TIER=${NEMOCLAW_POLICY_TIER}")

  resolve_chat_ui_url
  [[ -n "$CHAT_UI_URL" ]] && envs+=("CHAT_UI_URL=${CHAT_UI_URL}")

  if [[ "$FULL_WIZARD" == "1" ]]; then
    log "Running NemoClaw's full interactive onboarding wizard (FULL_WIZARD=1)"
    if [[ ! -t 0 && ! -t 1 ]]; then
      log "WARNING: no TTY detected — the wizard needs a terminal. Run this in 'brev shell'."
    fi
  else
    # Preset everything; the key was collected by prompt_for_key.
    [[ -n "${NVIDIA_INFERENCE_API_KEY:-}" ]] || fail "NVIDIA_INFERENCE_API_KEY is not set."
    envs+=(
      "NEMOCLAW_NON_INTERACTIVE=1"
      "NEMOCLAW_PROVIDER=${NEMOCLAW_PROVIDER}"
      "NVIDIA_INFERENCE_API_KEY=${NVIDIA_INFERENCE_API_KEY}"
      "NEMOCLAW_SANDBOX_NAME=${SANDBOX_NAME}"
    )
    log "Installing NemoClaw with preset settings (provider=${NEMOCLAW_PROVIDER}, sandbox=${SANDBOX_NAME})"
  fi

  log "Installer: ${NEMOCLAW_INSTALL_URL} (ref: ${NEMOCLAW_INSTALL_REF:-lkg})"
  # The installer reads the script on stdin; onboarding reads the terminal via
  # /dev/tty, so interactive prompts (FULL_WIZARD) still work in a real shell.
  if [[ "${#envs[@]}" -gt 0 ]]; then
    curl -fsSL "$NEMOCLAW_INSTALL_URL" | env "${envs[@]}" bash
  else
    curl -fsSL "$NEMOCLAW_INSTALL_URL" | bash
  fi

  ensure_nemoclaw_on_path
  command -v nemoclaw >/dev/null 2>&1 || fail "NemoClaw installed but 'nemoclaw' is not on PATH (looked in ~/.npm-global/bin, ~/.local/bin, npm prefix). Open a new shell and re-run."
  log "NemoClaw available at $(command -v nemoclaw)"
}

# Register one docs MCP server (name + URL) with Claude Code and/or Codex,
# idempotently. Returns 1 if neither CLI is present so the caller can advise.
_register_mcp() {
  local name="$1" url="$2" found=0

  if command -v claude >/dev/null 2>&1; then
    found=1
    if claude mcp list 2>/dev/null | grep -q "$url"; then
      log "${name} MCP already registered with Claude Code"
    else
      log "Registering ${name} MCP with Claude Code (user scope)"
      claude mcp add --scope user --transport http "$name" "$url" \
        || log "  Failed; add manually: claude mcp add --scope user --transport http ${name} ${url}"
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    found=1
    if codex mcp list 2>/dev/null | grep -q "$url"; then
      log "${name} MCP already registered with Codex"
    else
      log "Registering ${name} MCP with Codex"
      codex mcp add "$name" --url "$url" \
        || log "  Failed; add manually: codex mcp add ${name} --url ${url}"
    fi
  fi

  [[ "$found" == "1" ]]
}

# Register the NemoClaw + OpenShell docs MCP servers (agent-skills Method 1) so the
# agent can look up documentation for both layers of the stack. Each is optional.
add_docs_mcp() {
  if ! _register_mcp nemoclaw-docs "$DOCS_MCP_URL"; then
    log "Neither Claude Code nor Codex found; skipping docs MCP. Add later:"
    log "  Claude: claude mcp add --scope user --transport http nemoclaw-docs ${DOCS_MCP_URL}"
    log "          claude mcp add --scope user --transport http openshell-docs ${OPENSHELL_DOCS_MCP_URL}"
    log "  Codex:  codex mcp add nemoclaw-docs --url ${DOCS_MCP_URL}"
    log "          codex mcp add openshell-docs --url ${OPENSHELL_DOCS_MCP_URL}"
    return
  fi
  _register_mcp openshell-docs "$OPENSHELL_DOCS_MCP_URL"
}

print_dashboard_info() {
  command -v nemoclaw >/dev/null 2>&1 || { log "nemoclaw not on PATH; cannot print dashboard info"; return; }

  local url token brev_url
  url="$(nemoclaw "$SANDBOX_NAME" dashboard-url --quiet 2>/dev/null || true)"
  token="$(printf '%s\n' "$url" | sed -nE 's#.*[#?]token=([A-Za-z0-9]+).*#\1#p' | head -n1)"

  printf '\n'
  printf '================ NemoClaw / OpenClaw UI ================\n'
  if [[ -n "$CHAT_UI_URL" ]]; then
    if [[ -n "$token" ]]; then
      brev_url="${CHAT_UI_URL%/}/#token=${token}"
    else
      brev_url="${CHAT_UI_URL%/}/"
    fi
    printf '  Open in your browser (Brev tunnel):\n    %s\n' "$brev_url"
    printf '\n  Token: %s\n' "${token:-(run: nemoclaw ${SANDBOX_NAME} dashboard-url --quiet)}"
  else
    if [[ -n "$url" ]]; then
      printf '  Dashboard URL (tokenized, localhost):\n    %s\n' "$url"
    else
      printf '  Get the dashboard URL with:\n    nemoclaw %s dashboard-url --quiet\n' "$SANDBOX_NAME"
    fi
    printf '\n  The gateway listens on 127.0.0.1:18789 inside the instance.\n'
    printf '  From your laptop, reach it via a Brev port-forward:\n'
    printf '    brev port-forward <instance> -p 18789:18789\n'
    printf '  then open http://localhost:18789/ with the token above.\n'
  fi
  printf '\n  Terminal chat:  nemoclaw %s connect   then:  openclaw tui\n' "$SANDBOX_NAME"
  printf '  Status/logs:    nemoclaw %s status | logs\n' "$SANDBOX_NAME"
  printf '=======================================================\n'
}

main() {
  require_non_root
  require_cmd curl

  log "Step 1/3: Checking prerequisites (Docker)"
  check_docker

  if [[ "$FULL_WIZARD" != "1" ]]; then
    prompt_for_key
  fi

  log "Step 2/4: Installing NemoClaw + onboarding"
  install_nemoclaw

  if [[ "$INSTALL_DOCS_MCP" == "1" ]]; then
    log "Step 3/4: Registering NemoClaw docs MCP with Claude Code"
    add_docs_mcp
  else
    log "Step 3/4: Skipping NemoClaw docs MCP (INSTALL_DOCS_MCP=0)"
  fi

  log "Step 4/4: Access information"
  print_dashboard_info

  log "Done. If 'nemoclaw' is not found, run 'source ~/.bashrc' or open a new shell."
}

main "$@"
