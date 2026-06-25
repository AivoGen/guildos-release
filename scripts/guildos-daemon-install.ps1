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

function Get-ProcessArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) {
        return $env:PROCESSOR_ARCHITEW6432
    }
    return $env:PROCESSOR_ARCHITECTURE
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
} else {
    $downloadUrl = "https://github.com/AivoGen/guildos-release/releases/download/$releaseTag/$asset"
}

if (Test-Path -LiteralPath $daemonBin) {
    Write-Host "Daemon binary already present at $daemonBin - skipping download."
} else {
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
