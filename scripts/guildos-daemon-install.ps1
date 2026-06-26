param(
    [Alias('login-base-url')]
    [string]$LoginBaseUrl = ""
)

$ErrorActionPreference = "Stop"

function Enable-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Fail-WithExit([string]$Message, [int]$Code) {
    Write-Host $Message -ForegroundColor Red
    exit $Code
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProcessArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) {
        return $env:PROCESSOR_ARCHITEW6432
    }
    return $env:PROCESSOR_ARCHITECTURE
}

function Parse-Semver([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $match = [regex]::Match($Value, '^[^0-9]*(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) {
        return $null
    }
    return @(
        [int]$match.Groups[1].Value,
        [int]$match.Groups[2].Value,
        [int]$match.Groups[3].Value
    )
}

function Test-SemverGreaterOrEqual([string]$Have, [string]$Want) {
    $haveParts = Parse-Semver $Have
    $wantParts = Parse-Semver $Want
    if ($null -eq $haveParts -or $null -eq $wantParts) {
        return $false
    }
    for ($i = 0; $i -lt 3; $i += 1) {
        if ($haveParts[$i] -gt $wantParts[$i]) { return $true }
        if ($haveParts[$i] -lt $wantParts[$i]) { return $false }
    }
    return $true
}

function Resolve-LatestReleaseTag {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "https://github.com/AivoGen/guildos-release/releases/latest" -MaximumRedirection 5 -ErrorAction Stop
        $effective = $response.BaseResponse.ResponseUri.AbsoluteUri
        $match = [regex]::Match($effective, '/releases/tag/(v\d+\.\d+\.\d+[^/?#]*)')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    } catch {
        return ""
    }
    return ""
}

function Test-DaemonReusable([string]$DaemonBin, [string]$TargetVersion) {
    if (-not (Test-Path -LiteralPath $DaemonBin)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
        return $false
    }
    try {
        $localVersion = (& $DaemonBin --version 2>$null | Select-Object -First 1)
    } catch {
        return $false
    }
    if (-not (Test-SemverGreaterOrEqual $localVersion $TargetVersion)) {
        return $false
    }
    try {
        & $DaemonBin setup --help *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

if (-not (Test-IsAdministrator)) {
    Fail-WithExit "Administrator privileges are required. Re-run this installer from an Administrator PowerShell or terminal." 7
}

Enable-Tls12

if ($LoginBaseUrl -eq "") {
    $loginArgs = @()
} else {
    $loginArgs = @("--login-base-url", $LoginBaseUrl)
}

$arch = Get-ProcessArchitecture
if ($arch -ne "AMD64") {
    Fail-WithExit "unsupported Windows architecture: $arch (supports x64)" 3
}

$asset = "guildos-daemon-windows-x86_64.exe"
$daemonDir = Join-Path $env:USERPROFILE ".guildos\daemon"
$daemonBin = Join-Path $daemonDir "daemon.exe"
New-Item -ItemType Directory -Force -Path $daemonDir | Out-Null

$releaseTag = $env:GUILDOS_DAEMON_RELEASE_TAG
if ([string]::IsNullOrWhiteSpace($releaseTag)) {
    $downloadUrl = "https://github.com/AivoGen/guildos-release/releases/latest/download/$asset"
    $targetVersion = Resolve-LatestReleaseTag
} else {
    $downloadUrl = "https://github.com/AivoGen/guildos-release/releases/download/$releaseTag/$asset"
    $targetVersion = $releaseTag
}

if (Test-DaemonReusable $daemonBin $targetVersion) {
    Write-Host "Daemon binary at $daemonBin is current and supports setup - skipping download."
} else {
    if (Test-Path -LiteralPath $daemonBin) {
        Write-Host "Daemon binary at $daemonBin is old, unparseable, or lacks setup - replacing it."
    }
    $tmp = Join-Path $daemonDir ("daemon.tmp." + [System.Guid]::NewGuid().ToString("N") + ".exe")
    try {
        Write-Host "Downloading $asset from $downloadUrl ..."
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $tmp -ErrorAction Stop
        Move-Item -Force -LiteralPath $tmp -Destination $daemonBin
        Write-Host "Installed daemon to $daemonBin"
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -Force -LiteralPath $tmp
        }
        Fail-WithExit "download failed from $downloadUrl`: $_" 4
    }
}

Write-Host "Chaining to Stage 1 (daemon login) ..."
& $daemonBin login @loginArgs
if ($LASTEXITCODE -ne 0) {
    Fail-WithExit "Pairing did not complete. Re-run: `"$daemonBin`" login $($loginArgs -join ' ')" 5
}

Write-Host "Chaining to Stage 2 (daemon setup) ..."
& $daemonBin setup --daemon-binary $daemonBin
if ($LASTEXITCODE -ne 0) {
    Fail-WithExit "Setup did not complete. Re-run from an elevated terminal: `"$daemonBin`" setup --daemon-binary `"$daemonBin`"" 6
}

@"

guildos-daemon installed, paired, and started.

Check the service any time with:
       sc.exe query GuildOSDaemon

"@ | Write-Host
