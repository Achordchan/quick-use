$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$scriptUrl = "https://raw.githubusercontent.com/Achordchan/quick-use/main/scripts/codex-quick-use.ps1"
$scriptPath = Join-Path $env:TEMP "codex-quick-use.ps1"

Invoke-WebRequest -UseBasicParsing -Uri $scriptUrl -OutFile $scriptPath

$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)

if (-not [string]::IsNullOrWhiteSpace($env:CODEX_ACTION)) {
    $argsList += @("-Action", $env:CODEX_ACTION)
}
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_API_KEY)) {
    $argsList += @("-ApiKey", $env:CODEX_API_KEY)
}
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DIR_NAME)) {
    $argsList += @("-DirName", $env:CODEX_DIR_NAME)
}

& powershell @argsList
