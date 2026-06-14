# Codex 一键配置脚本

用于快速写入用户目录下的 `.codex/config.toml` 和 `.codex/auth.json`。Windows 使用 PowerShell，macOS 使用 Bash，不需要安装 Go。

## 一键脚本

下面命令会从 GitHub 下载脚本并执行。

Windows PowerShell：

```powershell
iwr -UseB https://raw.githubusercontent.com/Achordchan/quick-use/main/scripts/codex-quick-use.ps1 | iex
```

macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/Achordchan/quick-use/main/scripts/codex-quick-use.sh | bash
```

运行后会先显示菜单：

```text
1) Deploy
2) Restore default
3) Exit
```

对应含义：

- `Deploy`：一键部署，输入 API key 后写入配置。
- `Restore default`：恢复默认，优先从 `.bak` 还原；没有备份时移除本工具写入的配置。
- `Exit`：退出，不修改文件。

本机测试不要写真实 `.codex`，可以这样写到 `.codex1`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-quick-use.ps1 -DirName .codex1
```

```bash
CODEX_DIR_NAME=.codex1 bash scripts/codex-quick-use.sh
```

自动化测试可以跳过菜单：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codex-quick-use.ps1 -Action deploy -ApiKey sk-test -DirName .codex1
powershell -ExecutionPolicy Bypass -File .\scripts\codex-quick-use.ps1 -Action restore -DirName .codex1
```

```bash
CODEX_ACTION=deploy CODEX_API_KEY=sk-test CODEX_DIR_NAME=.codex1 bash scripts/codex-quick-use.sh
CODEX_ACTION=restore CODEX_DIR_NAME=.codex1 bash scripts/codex-quick-use.sh
```

## 写入内容

`config.toml` 开头会写入：

```toml
model_provider = "OpenAI"
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
goals = true
```

`auth.json` 会写入：

```json
{
  "OPENAI_API_KEY": "用户输入的 API key"
}
```

## 说明

- 正式使用默认写入用户目录下的 `.codex`。
- 本机测试可以写入 `.codex1`，不会影响真实 Codex 配置。
- 写入前会备份已有文件：`config.toml.bak`、`auth.json.bak`。
- API key 只保存到 `auth.json`，不会写入 `config.toml`。
