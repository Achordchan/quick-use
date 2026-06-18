#!/usr/bin/env sh
set -eu

script_url="https://raw.githubusercontent.com/Achordchan/quick-use/main/scripts/codex-quick-use.sh"
script_path="$(mktemp)"

cleanup() {
  rm -f "$script_path"
}
trap cleanup EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$script_url" -o "$script_path"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$script_path" "$script_url"
else
  echo "curl or wget is required" >&2
  exit 1
fi

bash "$script_path"
