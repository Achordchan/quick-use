#!/usr/bin/env bash
set -euo pipefail

api_key="${CODEX_API_KEY:-}"
dir_name="${CODEX_DIR_NAME:-.codex}"
action="${CODEX_ACTION:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-key)
      api_key="${2:-}"
      shift 2
      ;;
    --dir-name)
      dir_name="${2:-}"
      shift 2
      ;;
    --action)
      action="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "${dir_name// }" ]; then
  dir_name=".codex"
fi

target_dir="$HOME/$dir_name"
config_path="$target_dir/config.toml"
auth_path="$target_dir/auth.json"

managed_config='model_provider = "OpenAI"
model = "gpt-5.5"
review_model = "gpt-5.5"
model_reasoning_effort = "high"
disable_response_storage = true
network_access = "enabled"
windows_wsl_setup_acknowledged = true

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://sub.achord.cn:8443"
wire_api = "responses"
requires_openai_auth = true

[features]
goals = true'

backup_file_if_exists() {
  local path="$1"
  if [ -f "$path" ] && [ ! -f "$path.bak" ]; then
    cp "$path" "$path.bak"
  fi
}

remove_managed_config() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function managed_root_key(line, key) {
      if (line !~ /=/) return 0
      key = line
      sub(/=.*/, "", key)
      key = trim(key)
      return key == "model_provider" ||
        key == "model" ||
        key == "review_model" ||
        key == "model_reasoning_effort" ||
        key == "disable_response_storage" ||
        key == "network_access" ||
        key == "windows_wsl_setup_acknowledged"
    }
    {
      line = $0
      trimmed = trim(line)
      if (trimmed ~ /^\[.*\]$/) {
        in_root = 0
        in_managed = trimmed == "[model_providers.OpenAI]" || trimmed == "[features]"
        if (!in_managed) print line
        next
      }
      if (in_managed && (trimmed == "" || trimmed ~ /^#/ || trimmed ~ /=/)) next
      if (in_root && managed_root_key(trimmed)) next
      print line
    }
    BEGIN {
      in_root = 1
      in_managed = 0
    }
  '
}

trim_blank_edges() {
  sed '/./,$!d' | sed ':a;/^\n*$/{$d;N;ba;}'
}

read_api_key() {
  if [ -n "${api_key// }" ]; then
    return
  fi

  printf "Enter API key: "
  stty -echo
  read -r api_key
  stty echo
  printf "\n"

  if [ -z "${api_key// }" ]; then
    echo "API key cannot be empty" >&2
    exit 1
  fi
}

deploy() {
  read_api_key
  mkdir -p "$target_dir"

  existing_config=""
  if [ -f "$config_path" ]; then
    backup_file_if_exists "$config_path"
    existing_config="$(cat "$config_path")"
  fi

  cleaned_config="$(printf "%s" "$existing_config" | remove_managed_config | trim_blank_edges)"
  if [ -z "$cleaned_config" ]; then
    printf "%s\n" "$managed_config" > "$config_path"
  else
    printf "%s\n\n%s\n" "$managed_config" "$cleaned_config" > "$config_path"
  fi

  if [ -f "$auth_path" ]; then
    backup_file_if_exists "$auth_path"
  fi

  escaped_key="$(printf "%s" "$api_key" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  cat > "$auth_path" <<EOF
{
  "OPENAI_API_KEY": "$escaped_key"
}
EOF

  chmod 600 "$config_path" "$auth_path" 2>/dev/null || true
  echo "Deploy done: $target_dir"
}

restore_file() {
  local path="$1"
  if [ -f "$path.bak" ]; then
    cp "$path.bak" "$path"
    return 0
  fi
  return 1
}

restore_default() {
  if [ ! -d "$target_dir" ]; then
    echo "Nothing to restore: $target_dir"
    return
  fi

  if ! restore_file "$config_path"; then
    if [ -f "$config_path" ]; then
      cleaned_config="$(cat "$config_path" | remove_managed_config | trim_blank_edges)"
      if [ -z "$cleaned_config" ]; then
        rm -f "$config_path"
      else
        printf "%s\n" "$cleaned_config" > "$config_path"
      fi
    fi
  fi

  if ! restore_file "$auth_path"; then
    rm -f "$auth_path"
  fi

  echo "Restore done: $target_dir"
}

show_menu() {
  printf "\n"
  printf "1) Deploy\n"
  printf "2) Restore default\n"
  printf "3) Exit\n"
  printf "Select 1-3: "
  read -r choice
  case "$choice" in
    1) action="deploy" ;;
    2) action="restore" ;;
    3) action="exit" ;;
    *) echo "Invalid selection" >&2; exit 1 ;;
  esac
}

if [ -z "${action// }" ]; then
  show_menu
fi

case "$(printf "%s" "$action" | tr '[:upper:]' '[:lower:]')" in
  deploy) deploy ;;
  restore) restore_default ;;
  exit) echo "Exit" ;;
  *) echo "Unknown action: $action" >&2; exit 1 ;;
esac
