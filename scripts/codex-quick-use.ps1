param(
    [string]$ApiKey = "",
    [string]$DirName = ".codex"
)

$ErrorActionPreference = "Stop"

function Backup-FileIfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    }
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Escape-JsonString {
    param([string]$Value)

    return $Value.Replace("\", "\\").Replace('"', '\"')
}

function Get-ManagedConfig {
    return @'
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
'@
}

function Test-ManagedRootKey {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith("#") -or -not $Line.Contains("=")) {
        return $false
    }

    $key = $Line.Split("=", 2)[0].Trim()
    return @(
        "model_provider",
        "model",
        "review_model",
        "model_reasoning_effort",
        "disable_response_storage",
        "network_access",
        "windows_wsl_setup_acknowledged"
    ) -contains $key
}

function Remove-ManagedConfig {
    param([string]$Content)

    $lines = $Content -replace "`r`n", "`n" -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $inManagedSection = $false
    $inRoot = $true

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
            $inRoot = $false
            $inManagedSection = $trimmed -eq "[model_providers.OpenAI]" -or $trimmed -eq "[features]"
            if (-not $inManagedSection) {
                $out.Add($line)
            }
            continue
        }

        if ($inManagedSection) {
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#") -or $trimmed.Contains("=")) {
                continue
            }
        }

        if ($inRoot -and (Test-ManagedRootKey $trimmed)) {
            continue
        }

        $out.Add($line)
    }

    return (($out -join "`n").Trim())
}

function Merge-Config {
    param([string]$Existing)

    $managed = Get-ManagedConfig
    $cleaned = Remove-ManagedConfig $Existing
    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        return "$managed`n"
    }
    return "$managed`n`n$cleaned`n"
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $secureKey = Read-Host "Enter API key" -AsSecureString
    $plainPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plainPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plainPtr)
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "API key cannot be empty"
}

if ([string]::IsNullOrWhiteSpace($DirName)) {
    $DirName = ".codex"
}

$targetDir = Join-Path $HOME $DirName
$configPath = Join-Path $targetDir "config.toml"
$authPath = Join-Path $targetDir "auth.json"

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

$existingConfig = ""
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Backup-FileIfExists $configPath
    $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
}

$mergedConfig = Merge-Config $existingConfig
Write-Utf8NoBom -Path $configPath -Content $mergedConfig

if (Test-Path -LiteralPath $authPath -PathType Leaf) {
    Backup-FileIfExists $authPath
}

$escapedApiKey = Escape-JsonString $ApiKey
$authContent = @"
{
  "OPENAI_API_KEY": "$escapedApiKey"
}
"@
Write-Utf8NoBom -Path $authPath -Content ($authContent + "`n")

Write-Host "Done: $targetDir"
