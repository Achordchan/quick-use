param(
    [string]$ApiKey = "",
    [string]$DirName = ".codex",
    [string]$Action = ""
)

$ErrorActionPreference = "Stop"

function Backup-FileIfExists {
    param([string]$Path)

    $backupPath = "$Path.bak"
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $Path -Destination $backupPath
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

function Get-TargetPaths {
    if ([string]::IsNullOrWhiteSpace($script:DirName)) {
        $script:DirName = ".codex"
    }

    $targetDir = Join-Path $HOME $script:DirName
    return @{
        TargetDir = $targetDir
        ConfigPath = Join-Path $targetDir "config.toml"
        AuthPath = Join-Path $targetDir "auth.json"
    }
}

function Read-ApiKey {
    if (-not [string]::IsNullOrWhiteSpace($script:ApiKey)) {
        return $script:ApiKey
    }

    $secureKey = Read-Host "Enter API key" -AsSecureString
    $plainPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plainPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plainPtr)
    }
}

function Invoke-Deploy {
    $key = Read-ApiKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "API key cannot be empty"
    }

    $paths = Get-TargetPaths
    New-Item -ItemType Directory -Path $paths.TargetDir -Force | Out-Null

    $existingConfig = ""
    if (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf) {
        Backup-FileIfExists $paths.ConfigPath
        $existingConfig = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8
    }

    Write-Utf8NoBom -Path $paths.ConfigPath -Content (Merge-Config $existingConfig)

    if (Test-Path -LiteralPath $paths.AuthPath -PathType Leaf) {
        Backup-FileIfExists $paths.AuthPath
    }

    $escapedApiKey = Escape-JsonString $key
    $authContent = @"
{
  "OPENAI_API_KEY": "$escapedApiKey"
}
"@
    Write-Utf8NoBom -Path $paths.AuthPath -Content ($authContent + "`n")

    Write-Host "Deploy done: $($paths.TargetDir)"
}

function Restore-File {
    param([string]$Path)

    $backupPath = "$Path.bak"
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Copy-Item -LiteralPath $backupPath -Destination $Path -Force
        return $true
    }
    return $false
}

function Invoke-RestoreDefault {
    $paths = Get-TargetPaths
    if (-not (Test-Path -LiteralPath $paths.TargetDir -PathType Container)) {
        Write-Host "Nothing to restore: $($paths.TargetDir)"
        return
    }

    if (-not (Restore-File $paths.ConfigPath)) {
        if (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf) {
            $existingConfig = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8
            $cleanedConfig = Remove-ManagedConfig $existingConfig
            if ([string]::IsNullOrWhiteSpace($cleanedConfig)) {
                Remove-Item -LiteralPath $paths.ConfigPath -Force
            }
            else {
                Write-Utf8NoBom -Path $paths.ConfigPath -Content ($cleanedConfig + "`n")
            }
        }
    }

    if (-not (Restore-File $paths.AuthPath)) {
        if (Test-Path -LiteralPath $paths.AuthPath -PathType Leaf) {
            Remove-Item -LiteralPath $paths.AuthPath -Force
        }
    }

    Write-Host "Restore done: $($paths.TargetDir)"
}

function Show-Menu {
    Write-Host ""
    Write-Host "1) Deploy"
    Write-Host "2) Restore default"
    Write-Host "3) Exit"
    $choice = Read-Host "Select 1-3"
    switch ($choice) {
        "1" { $script:Action = "deploy" }
        "2" { $script:Action = "restore" }
        "3" { $script:Action = "exit" }
        default { throw "Invalid selection: $choice" }
    }
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Show-Menu
}

switch ($Action.Trim().ToLowerInvariant()) {
    "deploy" { Invoke-Deploy }
    "restore" { Invoke-RestoreDefault }
    "exit" { Write-Host "Exit" }
    default { throw "Unknown action: $Action" }
}
