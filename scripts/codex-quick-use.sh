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
      echo "未知参数：$1" >&2
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

managed_root_keys='model_provider = "OpenAI"
model = "gpt-5.5"
review_model = "gpt-5.5"
model_reasoning_effort = "high"
disable_response_storage = true
network_access = "enabled"
windows_wsl_setup_acknowledged = true'

managed_provider_block='[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://sub.achord.cn:8443"
wire_api = "responses"
requires_openai_auth = true'

backup_file_if_exists() {
  local path="$1"
  if [ -f "$path" ] && [ ! -f "$path.bak" ]; then
    cp "$path" "$path.bak"
  fi
}

split_config_for_merge() {
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
        in_managed_provider = trimmed == "[model_providers.OpenAI]"
        in_features = trimmed == "[features]"
        in_other_section = !(in_managed_provider || in_features)
        if (in_other_section) print "SECTION\t" line
        next
      }
      if (in_managed_provider) {
        if (trimmed == "" || trimmed ~ /^#/ || trimmed ~ /=/) next
        in_managed_provider = 0
        in_other_section = 1
        print "SECTION\t" line
        next
      }
      if (in_features) {
        if (trimmed == "" || trimmed ~ /^#/) next
        if (trimmed ~ /=/) {
          key = trimmed
          sub(/=.*/, "", key)
          key = trim(key)
          if (key != "goals") print "FEATURE\t" line
          next
        }
        in_features = 0
        in_other_section = 1
        print "SECTION\t" line
        next
      }
      if (in_other_section) {
        print "SECTION\t" line
        next
      }
      if (in_root) {
        if (managed_root_key(trimmed)) next
        print "ROOT\t" line
        next
      }
      print "SECTION\t" line
    }
    BEGIN {
      in_root = 1
      in_managed_provider = 0
      in_features = 0
      in_other_section = 0
    }
  '
}

trim_blank_edges() {
  sed '/./,$!d' | sed ':a;/^\n*$/{$d;N;ba;}'
}

extract_part() {
  local kind="$1"
  local text="$2"
  printf "%s\n" "$text" | awk -v kind="$kind" -F '\t' '$1==kind{print substr($0, length(kind)+2)}' | trim_blank_edges
}

build_features_block() {
  local include_goals="$1"
  local features_text="$2"
  local out=""

  if [ "$include_goals" = "1" ]; then
    out="goals = true"
  fi

  if [ -n "${features_text// }" ]; then
    if [ -n "$out" ]; then
      out="$out
$features_text"
    else
      out="$features_text"
    fi
  fi

  if [ -z "${out// }" ]; then
    return 0
  fi

  printf "[features]\n%s\n" "$out"
}

join_config_chunks() {
  local first=1
  local chunk
  for chunk in "$@"; do
    if [ -z "${chunk// }" ]; then
      continue
    fi
    if [ "$first" -eq 1 ]; then
      printf "%s\n" "$chunk"
      first=0
    else
      printf "\n%s\n" "$chunk"
    fi
  done
}

remove_managed_config() {
  local split_out root_text section_text feature_text
  split_out="$(printf "%s" "$1" | split_config_for_merge)"
  root_text="$(extract_part ROOT "$split_out")"
  section_text="$(extract_part SECTION "$split_out")"
  feature_text="$(extract_part FEATURE "$split_out")"
  join_config_chunks "$root_text" "$section_text" "$(build_features_block 0 "$feature_text")" | trim_blank_edges
}

merge_config() {
  local existing="$1"
  local split_out root_text section_text feature_text

  split_out="$(printf "%s" "$existing" | split_config_for_merge)"
  root_text="$(extract_part ROOT "$split_out")"
  section_text="$(extract_part SECTION "$split_out")"
  feature_text="$(extract_part FEATURE "$split_out")"
  join_config_chunks \
    "$managed_root_keys" \
    "$root_text" \
    "$managed_provider_block" \
    "$section_text" \
    "$(build_features_block 1 "$feature_text")"
}

read_api_key() {
  if [ -n "${api_key// }" ]; then
    return
  fi

  if [ -r /dev/tty ] && [ -t 1 ]; then
    printf "请输入 API key：" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r api_key < /dev/tty
    stty echo < /dev/tty
    printf "\n" > /dev/tty
  else
    printf "请输入 API key："
    if [ -t 0 ]; then
      stty -echo
    fi
    IFS= read -r api_key
    if [ -t 0 ]; then
      stty echo
    fi
    printf "\n"
  fi

  if [ -z "${api_key// }" ]; then
    echo "API key 不能为空" >&2
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

  merge_config "$existing_config" > "$config_path"

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
  echo "部署完成：$target_dir"
}

restore_file() {
  local path="$1"
  if [ -f "$path.bak" ]; then
    cp "$path.bak" "$path"
    rm -f "$path.bak"
    return 0
  fi
  return 1
}

restore_default() {
  if [ ! -d "$target_dir" ]; then
    echo "没有可恢复的配置：$target_dir"
    return
  fi

  if ! restore_file "$config_path"; then
    if [ -f "$config_path" ]; then
      cleaned_config="$(remove_managed_config "$(cat "$config_path")")"
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

  echo "恢复完成：$target_dir"
}

show_menu() {
  if [ -r /dev/tty ] && [ -t 1 ]; then
    printf "\n" > /dev/tty
    printf "1) 部署配置\n" > /dev/tty
    printf "2) 恢复默认配置\n" > /dev/tty
    printf "3) 退出\n" > /dev/tty
    printf "请选择 1-3：" > /dev/tty
    IFS= read -r choice < /dev/tty
  else
    printf "\n"
    printf "1) 部署配置\n"
    printf "2) 恢复默认配置\n"
    printf "3) 退出\n"
    printf "请选择 1-3："
    IFS= read -r choice
  fi

  case "$choice" in
    1) action="deploy" ;;
    2) action="restore" ;;
    3) action="exit" ;;
    *) echo "无效选项" >&2; exit 1 ;;
  esac
}

if [ -z "${action// }" ]; then
  show_menu
fi

case "$(printf "%s" "$action" | tr '[:upper:]' '[:lower:]')" in
  deploy) deploy ;;
  restore) restore_default ;;
  exit) echo "已退出" ;;
  *) echo "未知操作：$action" >&2; exit 1 ;;
esac
