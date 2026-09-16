param(
    [string]$ApiKey = "",
    [string]$DirName = ".codex",
    [string]$Action = ""
)

$ErrorActionPreference = "Stop"

function Save-OriginalFileState {
    param([string]$Path)

    $backupPath = "$Path.bak"
    $absentPath = "$Path.quick-use-absent"
    if ((Test-Path -LiteralPath $backupPath) -or (Test-Path -LiteralPath $absentPath)) {
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination $backupPath
    }
    else {
        Write-Utf8NoBom -Path $absentPath -Content "absent-v1`n"
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

function Get-ManagedRootKeys {
    $content = @()
    $content += 'model_provider = "OpenAI"'
    $content += 'model = "gpt-5.5"'
    $content += 'review_model = "gpt-5.5"'
    $content += 'model_reasoning_effort = "high"'
    $content += 'disable_response_storage = true'
    $content += 'network_access = "enabled"'
    $content += 'windows_wsl_setup_acknowledged = true'
    return ($content -join "`n")
}

function Get-ManagedProviderBlock {
    $content = @()
    $content += '[model_providers.OpenAI]'
    $content += 'name = "OpenAI"'
    $content += 'base_url = "https://sub.achord.cn:8443"'
    $content += 'wire_api = "responses"'
    $content += 'requires_openai_auth = true'
    return ($content -join "`n")
}

function Get-ConfigKey {
    param([string]$Line)

    $key = $Line.Split("=", 2)[0].Trim()
    if ($key -match '^"([A-Za-z0-9_-]+)"$' -or $key -match "^'([A-Za-z0-9_-]+)'$") {
        return $Matches[1]
    }
    return $key
}

function Test-ManagedRootKey {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith("#") -or -not $Line.Contains("=")) {
        return $false
    }

    $key = Get-ConfigKey $Line
    return @(
        "model_provider",
        "model",
        "review_model",
        "model_reasoning_effort",
        "disable_response_storage",
        "network_access",
        "windows_wsl_setup_acknowledged"
    ) -ccontains $key
}

function Split-ConfigForMerge {
    param([string]$Content)

    $lines = @()
    if (-not [string]::IsNullOrEmpty($Content)) {
        $lines = $Content -replace "`r`n", "`n" -split "`n"
    }

    $rootLines = New-Object System.Collections.Generic.List[string]
    $sectionLines = New-Object System.Collections.Generic.List[string]
    $preservedFeatures = New-Object System.Collections.Generic.List[string]
    $inManagedProvider = $false
    $inFeatures = $false
    $inOtherSection = $false
    $inRoot = $true

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^(\[.*?\])\s*(?:#.*)?$') {
            $header = $Matches[1]
            $inRoot = $false
            $inManagedProvider = $header -cmatch '^\[\s*(?:model_providers|"model_providers"|''model_providers'')\s*\.\s*(?:OpenAI|"OpenAI"|''OpenAI'')\s*\]$'
            $inFeatures = $header -cmatch '^\[\s*(?:features|"features"|''features'')\s*\]$'
            $inOtherSection = -not ($inManagedProvider -or $inFeatures)
            if ($inOtherSection) {
                $sectionLines.Add($line)
            }
            continue
        }

        if ($inManagedProvider) {
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#") -or $trimmed.Contains("=")) {
                continue
            }
            $inManagedProvider = $false
            $inOtherSection = $true
            $sectionLines.Add($line)
            continue
        }

        if ($inFeatures) {
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            if ($trimmed.Contains("=")) {
                $key = Get-ConfigKey $trimmed
                if ($key -cne "goals") {
                    $preservedFeatures.Add($line)
                }
                continue
            }
            $inFeatures = $false
            $inOtherSection = $true
            $sectionLines.Add($line)
            continue
        }

        if ($inOtherSection) {
            $sectionLines.Add($line)
            continue
        }

        if ($inRoot) {
            if (Test-ManagedRootKey $trimmed) {
                continue
            }
            $rootLines.Add($line)
            continue
        }

        $sectionLines.Add($line)
    }

    return @{
        Root = (($rootLines -join "`n").Trim())
        Sections = (($sectionLines -join "`n").Trim())
        PreservedFeatures = @($preservedFeatures)
    }
}

function Build-FeaturesBlock {
    param(
        [string[]]$PreservedFeatures,
        [bool]$IncludeGoals
    )

    $featureLines = New-Object System.Collections.Generic.List[string]
    if ($IncludeGoals) {
        $featureLines.Add("goals = true")
    }
    foreach ($line in $PreservedFeatures) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $featureLines.Add($line)
        }
    }

    if ($featureLines.Count -eq 0) {
        return ""
    }

    return ("[features]`n" + ($featureLines -join "`n"))
}

function Join-ConfigChunks {
    param([string[]]$Chunks)

    $nonEmpty = New-Object System.Collections.Generic.List[string]
    foreach ($chunk in $Chunks) {
        if (-not [string]::IsNullOrWhiteSpace($chunk)) {
            $nonEmpty.Add($chunk.Trim())
        }
    }
    if ($nonEmpty.Count -eq 0) {
        return ""
    }
    return (($nonEmpty -join "`n`n").Trim())
}

function Remove-ManagedConfig {
    param([string]$Content)

    $parts = Split-ConfigForMerge $Content
    $features = Build-FeaturesBlock -PreservedFeatures $parts.PreservedFeatures -IncludeGoals:$false
    return (Join-ConfigChunks @($parts.Root, $parts.Sections, $features))
}

function Merge-Config {
    param([string]$Existing)

    $parts = Split-ConfigForMerge $Existing
    $features = Build-FeaturesBlock -PreservedFeatures $parts.PreservedFeatures -IncludeGoals:$true
    $merged = Join-ConfigChunks @(
        (Get-ManagedRootKeys),
        $parts.Root,
        (Get-ManagedProviderBlock),
        $parts.Sections,
        $features
    )
    return ($merged + "`n")
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

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_API_KEY)) {
        return $env:CODEX_API_KEY
    }

    $secureKey = Read-Host "请输入 API key" -AsSecureString
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
        throw "API key 不能为空"
    }

    $paths = Get-TargetPaths
    New-Item -ItemType Directory -Path $paths.TargetDir -Force | Out-Null

    $existingConfig = ""
    if (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf) {
        $existingConfig = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8
    }

    $mergedConfig = Merge-Config $existingConfig
    Save-OriginalFileState $paths.ConfigPath
    Save-OriginalFileState $paths.AuthPath
    Write-Utf8NoBom -Path $paths.ConfigPath -Content $mergedConfig

    $escapedApiKey = Escape-JsonString $key
    $authContent = "{`n  `"OPENAI_API_KEY`": `"$escapedApiKey`"`n}"
    Write-Utf8NoBom -Path $paths.AuthPath -Content ($authContent + "`n")

    Write-Host "部署完成：$($paths.TargetDir)"
}

function Restore-File {
    param([string]$Path)

    $backupPath = "$Path.bak"
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Copy-Item -LiteralPath $backupPath -Destination $Path -Force
        Remove-Item -LiteralPath $backupPath -Force
        return $true
    }
    return $false
}

function Invoke-RestoreDefault {
    $paths = Get-TargetPaths
    if (-not (Test-Path -LiteralPath $paths.TargetDir -PathType Container)) {
        Write-Host "没有可恢复的配置：$($paths.TargetDir)"
        return
    }

    $configWasAbsent = "$($paths.ConfigPath).quick-use-absent"
    $authWasAbsent = "$($paths.AuthPath).quick-use-absent"
    if (-not (Restore-File $paths.ConfigPath) -and (Test-Path -LiteralPath $configWasAbsent -PathType Leaf)) {
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

    if (-not (Restore-File $paths.AuthPath) -and (Test-Path -LiteralPath $authWasAbsent -PathType Leaf)) {
        if (Test-Path -LiteralPath $paths.AuthPath -PathType Leaf) {
            Remove-Item -LiteralPath $paths.AuthPath -Force
        }
    }

    foreach ($marker in @($configWasAbsent, $authWasAbsent)) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            Remove-Item -LiteralPath $marker -Force
        }
    }
    Write-Host "恢复完成：$($paths.TargetDir)"
}

function Show-Menu {
    Write-Host ""
    Write-Host "1) 部署配置"
    Write-Host "2) 恢复默认配置"
    Write-Host "3) 退出"
    $choice = Read-Host "请选择 1-3"
    switch ($choice) {
        "1" { $script:Action = "deploy" }
        "2" { $script:Action = "restore" }
        "3" { $script:Action = "exit" }
        default { throw "无效选项：$choice" }
    }
}

if ([string]::IsNullOrWhiteSpace($Action)) {
    Show-Menu
}

switch ($Action.Trim().ToLowerInvariant()) {
    "deploy" { Invoke-Deploy }
    "restore" { Invoke-RestoreDefault }
    "exit" { Write-Host "已退出" }
    default { throw "未知操作：$Action" }
}
