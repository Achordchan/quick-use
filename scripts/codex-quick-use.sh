#!/usr/bin/env bash
set -euo pipefail

api_key="${CODEX_API_KEY:-}"
dir_name="${CODEX_DIR_NAME:-.codex}"

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
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "${api_key// }" ]; then
  printf "Enter API key: "
  stty -echo
  read -r api_key
  stty echo
  printf "\n"
fi

if [ -z "${api_key// }" ]; then
  echo "API key cannot be empty" >&2
  exit 1
fi

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

mkdir -p "$target_dir"

existing_config=""
if [ -f "$config_path" ]; then
  cp "$config_path" "$config_path.bak"
  existing_config="$(cat "$config_path")"
fi

cleaned_config="$(printf "%s" "$existing_config" | remove_managed_config | sed '/./,$!d' | sed ':a;/^\n*$/{$d;N;ba;}')"
if [ -z "$cleaned_config" ]; then
  printf "%s\n" "$managed_config" > "$config_path"
else
  printf "%s\n\n%s\n" "$managed_config" "$cleaned_config" > "$config_path"
fi

if [ -f "$auth_path" ]; then
  cp "$auth_path" "$auth_path.bak"
fi

escaped_key="$(printf "%s" "$api_key" | sed 's/\\/\\\\/g; s/"/\\"/g')"
cat > "$auth_path" <<EOF
{
  "OPENAI_API_KEY": "$escaped_key"
}
EOF

chmod 600 "$config_path" "$auth_path" 2>/dev/null || true
echo "Done: $target_dir"
