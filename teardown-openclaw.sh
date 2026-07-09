#!/usr/bin/env bash
#
# teardown-openclaw.sh
# Removes everything installed by install-openclaw-latest.sh so the script
# can be rerun from scratch. Safe by default: prints a plan and asks before
# deleting.
#
# By default this removes EVERYTHING, including Node.js/nvm and the PATH line
# added to ~/.bashrc, for a fully pristine box. Pass --keep-node to preserve
# the Node.js/nvm install.
#
# Usage:
#   ./teardown-openclaw.sh            # inspect + confirm + remove everything
#   ./teardown-openclaw.sh --yes      # skip the confirmation prompt
#   ./teardown-openclaw.sh --dry-run  # show what would happen, delete nothing
#   ./teardown-openclaw.sh --keep-node  # keep Node.js/nvm (reused by installer)

set -uo pipefail

ASSUME_YES=0
DRY_RUN=0
PURGE_NODE=1
for arg in "$@"; do
  case "$arg" in
    --yes|-y)      ASSUME_YES=1 ;;
    --dry-run|-n)  DRY_RUN=1 ;;
    --keep-node)   PURGE_NODE=0 ;;
    --purge-node)  PURGE_NODE=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

log()  { printf '\033[0;34m[teardown]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }

# run <description> <command...>
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would: %s\n' "$desc"
  else
    "$@" >/dev/null 2>&1 && ok "$desc" || warn "skipped/failed: $desc"
  fi
}

load_nvm() {
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$nvm_dir/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$nvm_dir/nvm.sh" >/dev/null 2>&1 || true
  fi
}

show_nvm_packages() {
  local pkg version_dir
  [ -d "$HOME/.nvm/versions/node" ] || return 0
  for version_dir in "$HOME"/.nvm/versions/node/*; do
    [ -d "$version_dir" ] || continue
    for pkg in "$@"; do
      { [ -e "$version_dir/bin/$pkg" ] || [ -L "$version_dir/bin/$pkg" ]; } && echo "    present: $version_dir/bin/$pkg"
      { [ -e "$version_dir/lib/node_modules/$pkg" ] || [ -L "$version_dir/lib/node_modules/$pkg" ]; } && echo "    present: $version_dir/lib/node_modules/$pkg"
    done
  done
}

remove_nvm_packages() {
  local pkg version_dir removed
  [ -d "$HOME/.nvm/versions/node" ] || return 0
  for version_dir in "$HOME"/.nvm/versions/node/*; do
    [ -d "$version_dir" ] || continue
    for pkg in "$@"; do
      if [ -e "$version_dir/bin/$pkg" ] || [ -L "$version_dir/bin/$pkg" ] ||
         [ -e "$version_dir/lib/node_modules/$pkg" ] || [ -L "$version_dir/lib/node_modules/$pkg" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
          printf '  would: rm -rf %s %s\n' "$version_dir/bin/$pkg" "$version_dir/lib/node_modules/$pkg"
        else
          removed="$(basename "$version_dir")/$pkg"
          rm -rf "$version_dir/bin/$pkg" "$version_dir/lib/node_modules/$pkg" \
            && ok "removed nvm package $removed" \
            || warn "skipped/failed: remove nvm package $removed"
        fi
      fi
    done
  done
}

load_nvm

echo
log "=== 1/6  Inspecting current OpenClaw footprint ==="
echo "  binaries:"
for b in openclaw; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && echo "    $b -> $p" || echo "    $b -> (not found)"
done
echo "  directories:"
for d in ~/.config/openclaw ~/.local/state/openclaw ~/.local/share/openclaw \
         ~/.cache/openclaw ~/.openclaw ~/.npm-global/lib/node_modules/openclaw; do
  [ -e "$d" ] && echo "    present: $d" || true
done
show_nvm_packages openclaw
echo "  systemd user services:"
systemctl --user list-unit-files 2>/dev/null | grep -i openclaw | sed 's/^/    /' || echo "    (none / systemd unavailable)"
echo "  linger status: $(loginctl show-user "$USER" 2>/dev/null | grep -i linger || echo 'unknown')"
echo "  ~/.bashrc PATH lines referencing .npm-global:"
grep -n '.npm-global' "$HOME/.bashrc" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  read -r -p "Proceed with removal? [y/N] " reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
fi

log "=== 2/6  Stopping the gateway ==="
run "openclaw gateway stop" openclaw gateway stop

log "=== 3/6  Removing systemd user service + lingering ==="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "  would: stop/disable openclaw systemd user units, disable linger"
else
  for unit in $(systemctl --user list-unit-files 2>/dev/null | grep -io 'openclaw[^ ]*' | sort -u); do
    systemctl --user stop "$unit"    >/dev/null 2>&1 && ok "stopped $unit"    || true
    systemctl --user disable "$unit" >/dev/null 2>&1 && ok "disabled $unit"   || true
  done
  rm -f "$HOME/.config/systemd/user/"*openclaw* 2>/dev/null && ok "removed unit files" || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  loginctl disable-linger "$USER" >/dev/null 2>&1 && ok "disabled linger" || true
fi

log "=== 4/6  Removing CLI (npm global) ==="
run "npm rm -g openclaw" npm rm -g openclaw
run "rm ~/.npm-global/bin/openclaw" rm -f "$HOME/.npm-global/bin/openclaw"
remove_nvm_packages openclaw

log "=== 5/6  Removing config / state / data dirs ==="
for d in "$HOME/.config/openclaw" "$HOME/.local/state/openclaw" \
         "$HOME/.local/share/openclaw" "$HOME/.cache/openclaw" \
         "$HOME/.openclaw"; do
  run "rm -rf $d" rm -rf "$d"
done

log "=== 6/6  Node.js / nvm + shell config ==="
if [ "$PURGE_NODE" -eq 1 ]; then
  run "rm -rf ~/.nvm" rm -rf "$HOME/.nvm"
  run "rm -rf ~/.npm-global" rm -rf "$HOME/.npm-global"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would: strip .npm-global PATH lines from ~/.bashrc"
  elif [ -f "$HOME/.bashrc" ]; then
    sed -i.openclaw-bak '/\.npm-global/d' "$HOME/.bashrc" && ok "stripped PATH lines from ~/.bashrc (backup: ~/.bashrc.openclaw-bak)"
  fi
  warn "Node/nvm removed. Check ~/.bashrc / ~/.zshrc for leftover nvm init lines."
else
  ok "kept Node.js/nvm and ~/.npm-global (--keep-node)."
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  log "Dry run complete — nothing was deleted."
else
  log "Teardown complete. Rerun the installer with:"
  echo "    ./install-openclaw-latest.sh"
fi
