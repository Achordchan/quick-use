# Codex 一键配置脚本

用于快速写入用户目录下的 `.codex/config.toml` 和 `.codex/auth.json`。Windows 使用 PowerShell，macOS 使用 Bash，不需要安装 Go。

## 一键脚本

下面命令会从 GitHub 下载启动器并执行，启动器会自动下载主脚本到临时文件，避免菜单输入被管道占用。

Windows PowerShell：

```powershell
irm https://raw.githubusercontent.com/Achordchan/quick-use/main/install.ps1 | iex
```

macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/Achordchan/quick-use/main/install.sh | sh
```

运行后会先显示菜单：

```text
1) 部署配置
2) 恢复默认配置
3) 退出
```

对应含义：

- `部署配置`：输入 API key 后写入配置。
- `恢复默认配置`：优先从 `.bak` 还原；有“部署前不存在”的记录时清理本工具写入的内容；两者都没有时保留现有文件。重复恢复不会删除已还原的配置或登录信息。
- `退出`：不修改文件，直接退出。

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
- 部署前不存在的文件会生成对应的 `.quick-use-absent` 状态文件；重复部署保留首次备份或状态记录，恢复完成后清理记录。
- 旧版 `.bak` 备份仍可恢复。旧版部署若没有备份，也没有状态记录，将保留现有文件，避免误删用户配置。
- API key 只保存到 `auth.json`，不会写入 `config.toml`。

## 回归测试

安装 Python 3.11 或更高版本后运行：

```text
python -m unittest discover -s tests -v
```

测试自动选择可用的 PowerShell 和 Bash，并使用临时目录，不修改用户的真实 Codex 配置。GitHub Actions 分别验证 Windows、macOS 和 Linux。
