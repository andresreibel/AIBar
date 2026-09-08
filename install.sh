#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${AIBAR_REPO_DIR:-$SCRIPT_DIR}"
INSTALL_BASHRC=0
FORCE_BASHRC=0
OS_NAME="$(uname -s)"
STATE_DIR="$HOME/.codex/aibar"
LEGACY_STATE_DIR="$HOME/.codex/claudexbar"

usage() {
  cat <<'EOF'
Install AIBar for macOS or Linux

Usage:
  ./install.sh [options]

Options:
  --bashrc        Install the optional `aibar` shell command on Linux
  --source <dir>  Read source files from this checkout
  --force-bashrc  Replace an existing ~/.bashrc.d/aibar helper
  -h, --help      Show this help

macOS installs /Applications/AIBar.app.
Linux installs ~/.local/bin/aibar.ts and ~/.local/bin/aibar-dashboard.
EOF
}

resolve_repo_dir() {
  if [[ ! -f "$REPO_DIR/aibar.ts" && -f "$HOME/Code/AIBar/aibar.ts" ]]; then
    REPO_DIR="$HOME/Code/AIBar"
  fi
  if [[ ! -f "$REPO_DIR/aibar.ts" || ! -f "$REPO_DIR/aibar-linux.py" ]]; then
    echo "Could not find aibar.ts and aibar-linux.py in $REPO_DIR."
    echo "Set AIBAR_REPO_DIR or pass --source <dir>."
    exit 1
  fi
}

preflight_state_migration() {
  if [[ -e "$LEGACY_STATE_DIR" && -e "$STATE_DIR" ]]; then
    echo "Cannot migrate AIBar state because both paths exist:"
    echo "  $LEGACY_STATE_DIR"
    echo "  $STATE_DIR"
    echo "Move or reconcile one directory, then rerun the installer."
    exit 1
  fi
}

migrate_state() {
  if [[ -d "$LEGACY_STATE_DIR" ]]; then
    mkdir -p "$(dirname "$STATE_DIR")"
    mv "$LEGACY_STATE_DIR" "$STATE_DIR"
    rm -f "$STATE_DIR"/render-*.json "$STATE_DIR/claude-last-good.json" "$STATE_DIR/claude-backoff.json"
    echo "Migrated state: $STATE_DIR"
  fi
}

preflight_macos_preferences() {
  local old_value new_value
  old_value="$(defaults read com.andresreibel.claudexbar dismissedNotificationSignature 2>/dev/null || true)"
  new_value="$(defaults read com.andresreibel.aibar dismissedNotificationSignature 2>/dev/null || true)"
  if [[ -n "$old_value" && -n "$new_value" && "$old_value" != "$new_value" ]]; then
    echo "AIBar notification settings conflict between the old and new app identities."
    echo "Clear one dismissedNotificationSignature value, then rerun the installer."
    exit 1
  fi
}

migrate_macos_preferences() {
  local old_value new_value
  old_value="$(defaults read com.andresreibel.claudexbar dismissedNotificationSignature 2>/dev/null || true)"
  new_value="$(defaults read com.andresreibel.aibar dismissedNotificationSignature 2>/dev/null || true)"
  if [[ -n "$old_value" && -z "$new_value" ]]; then
    defaults write com.andresreibel.aibar dismissedNotificationSignature "$old_value"
  fi
  defaults delete com.andresreibel.claudexbar >/dev/null 2>&1 || true
}

install_macos() {
  if [[ "$INSTALL_BASHRC" -eq 1 || "$FORCE_BASHRC" -eq 1 ]]; then
    echo "Linux integration flags are not valid on macOS."
    exit 1
  fi
  command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]] || {
    echo "Bun is required: https://bun.sh"
    exit 1
  }
  command -v swift >/dev/null 2>&1 || {
    echo "Swift is required. Install Xcode Command Line Tools first."
    exit 1
  }
  command -v rsvg-convert >/dev/null 2>&1 || {
    echo "rsvg-convert is required. Install it with: brew install librsvg"
    exit 1
  }

  preflight_state_migration
  preflight_macos_preferences
  make -C "$REPO_DIR" install
  pkill -x ClaudexBar 2>/dev/null || true
  rm -rf /Applications/ClaudexBar.app
  migrate_state
  migrate_macos_preferences
  echo "Installed: /Applications/AIBar.app"
  echo "Open it with: open /Applications/AIBar.app"
}

migrate_linux_widget() {
  local config="$HOME/.config/omarchy/shell.json"
  [[ -f "$config" ]] || return

  python3 - "$config" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
legacy = []
current = []

def collect(value):
    if isinstance(value, dict):
        if value.get("id") == "claudexbar":
            legacy.append(value)
        elif value.get("id") == "aibar":
            current.append(value)
        for child in value.values():
            collect(child)
    elif isinstance(value, list):
        for child in value:
            collect(child)

collect(data)
if not legacy:
    raise SystemExit(0)
if len(legacy) != 1 or current:
    raise SystemExit(
        f"Cannot migrate AIBar widget in {path}: "
        f"found {len(legacy)} old and {len(current)} new entries."
    )

legacy[0].clear()
legacy[0].update({
    "id": "aibar",
    "type": "command",
    "exec": "~/.bun/bin/bun ~/.local/bin/aibar.ts",
    "interval": 1,
    "onClick": "~/.local/bin/aibar-dashboard",
})
temporary = path.with_name(path.name + ".aibar.tmp")
temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
os.chmod(temporary, path.stat().st_mode)
temporary.replace(path)
print(f"Migrated widget: {path}")
PY
}


install_linux() {
  preflight_state_migration
  migrate_linux_widget
  mkdir -p "$HOME/.local/bin"
  cp "$REPO_DIR/aibar.ts" "$HOME/.local/bin/aibar.ts"
  cp "$REPO_DIR/aibar-linux.py" "$HOME/.local/bin/aibar-dashboard"
  chmod +x "$HOME/.local/bin/aibar.ts" "$HOME/.local/bin/aibar-dashboard"
  migrate_state
  rm -f "$HOME/.local/bin/claudexbar.ts" "$HOME/.local/bin/claudexbar-dashboard"
  rm -f "$HOME/.bashrc.d/claudexbar"
  echo "Installed: ~/.local/bin/aibar.ts"
  echo "Installed: ~/.local/bin/aibar-dashboard"
  echo "Source:    $REPO_DIR"
}

install_bashrc_integration() {
  local target="$HOME/.bashrc.d/aibar"
  mkdir -p "$HOME/.bashrc.d"
  if [[ -f "$target" && "$FORCE_BASHRC" -ne 1 ]]; then
    echo "Skipped existing $target. Use --force-bashrc to replace it."
    return
  fi
  cat > "$target" <<'EOF'
# AIBar command

aibar() {
  ~/.bun/bin/bun ~/.local/bin/aibar.ts "$@"
}
EOF
  echo "Installed shell command: aibar"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bashrc)
      INSTALL_BASHRC=1
      shift
      ;;
    --source)
      [[ $# -ge 2 ]] || { echo "Missing value for --source"; exit 1; }
      REPO_DIR="$2"
      shift 2
      ;;
    --force-bashrc)
      FORCE_BASHRC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

resolve_repo_dir

case "$OS_NAME" in
  Darwin)
    install_macos
    ;;
  Linux)
    install_linux
    if [[ "$INSTALL_BASHRC" -eq 1 ]]; then
      install_bashrc_integration
    fi
    ;;
  *)
    echo "Unsupported operating system: $OS_NAME"
    exit 1
    ;;
esac
