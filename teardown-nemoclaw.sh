#!/usr/bin/env bash
#
# teardown-nemoclaw.sh
# Removes everything installed by install-nemoclaw-latest.sh so the script
# can be rerun from scratch. Safe by default: prints a plan and asks before
# deleting. Node.js/nvm is preserved unless --purge-node is passed.
#
# By default this removes EVERYTHING, including Node.js/nvm, for a fully
# pristine box. Pass --keep-node to preserve the Node.js/nvm install.
#
# Usage:
#   ./teardown-nemoclaw.sh            # inspect + confirm + remove everything
#   ./teardown-nemoclaw.sh --yes      # skip the confirmation prompt
#   ./teardown-nemoclaw.sh --dry-run  # show what would happen, delete nothing
#   ./teardown-nemoclaw.sh --keep-node  # keep Node.js/nvm (reused by installer)

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
log "=== 1/5  Inspecting current NemoClaw footprint ==="
echo "  binaries:"
for b in nemoclaw openshell openclaw; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && echo "    $b -> $p" || echo "    $b -> (not found)"
done
echo "  directories:"
for d in ~/.local/state/nemoclaw ~/.config/nemoclaw ~/.local/share/nemoclaw \
         ~/.cache/nemoclaw ~/nemoclaw ~/.nemoclaw; do
  [ -e "$d" ] && echo "    present: $d" || true
done
show_nvm_packages nemoclaw openshell openclaw
echo "  docker containers:"
docker ps -a --filter "name=openshell" --filter "name=nemoclaw" \
  --format '    {{.Names}} ({{.Status}})' 2>/dev/null || echo "    (docker unavailable)"
echo "  docker networks/volumes:"
docker network ls --filter "name=openshell" --format '    net: {{.Name}}' 2>/dev/null
docker volume  ls --filter "name=openshell" --format '    vol: {{.Name}}' 2>/dev/null
echo

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  read -r -p "Proceed with removal? [y/N] " reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
fi

log "=== 2/5  Stopping & removing Docker artifacts ==="
run "stop openshell gateway" openshell gateway stop
if [ "$DRY_RUN" -eq 1 ]; then
  echo "  would: remove openshell/nemoclaw containers, networks, volumes"
else
  ids="$(docker ps -aq --filter "name=openshell" --filter "name=nemoclaw" 2>/dev/null)"
  [ -n "$ids" ] && { echo "$ids" | xargs -r docker rm -f >/dev/null 2>&1 && ok "removed containers"; } || ok "no containers"
  docker network ls -q --filter "name=openshell" 2>/dev/null | xargs -r docker network rm >/dev/null 2>&1 && ok "removed networks" || true
  docker volume  ls -q --filter "name=openshell" 2>/dev/null | xargs -r docker volume  rm >/dev/null 2>&1 && ok "removed volumes" || true
fi

log "=== 3/5  Removing CLI, shims, npm links ==="
run "npm rm -g nemoclaw openclaw openshell" npm rm -g nemoclaw openclaw openshell
run "rm shim ~/.local/bin/nemoclaw"  rm -f "$HOME/.local/bin/nemoclaw"
run "rm shim ~/.local/bin/openshell" rm -f "$HOME/.local/bin/openshell"
remove_nvm_packages nemoclaw openclaw openshell

log "=== 4/5  Removing config / state / source dirs ==="
for d in "$HOME/.local/state/nemoclaw" "$HOME/.config/nemoclaw" \
         "$HOME/.local/share/nemoclaw" "$HOME/.cache/nemoclaw" \
         "$HOME/nemoclaw" "$HOME/.nemoclaw"; do
  run "rm -rf $d" rm -rf "$d"
done

log "=== 5/5  Node.js / nvm ==="
if [ "$PURGE_NODE" -eq 1 ]; then
  run "rm -rf ~/.nvm" rm -rf "$HOME/.nvm"
  warn "Node/nvm removed. Also strip nvm lines from ~/.bashrc / ~/.zshrc manually if present."
else
  ok "kept Node.js/nvm (--keep-node). Omit that flag to remove it too."
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  log "Dry run complete — nothing was deleted."
else
  log "Teardown complete. Rerun the installer with:"
  echo "    FULL_WIZARD=1 ./install-nemoclaw-latest.sh"
fi
