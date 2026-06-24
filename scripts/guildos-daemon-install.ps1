param(
    [string]$LoginBaseUrl = ""
)

$ErrorActionPreference = "Stop"

if ($LoginBaseUrl -eq "") {
    $loginArgs = @()
} else {
    $loginArgs = @("--login-base-url", $LoginBaseUrl)
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Write-Error "unsupported Windows architecture: $arch (supports x64)"
    exit 3
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
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $tmp
        Move-Item -Force -LiteralPath $tmp -Destination $daemonBin
        Write-Host "Installed daemon to $daemonBin"
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -Force -LiteralPath $tmp
        }
        Write-Error "download failed from $downloadUrl`: $_"
        exit 4
    }
}

Write-Host "Chaining to Stage 1 (daemon login) ..."
& $daemonBin login @loginArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Pairing did not complete. Re-run: `"$daemonBin`" login $($loginArgs -join ' ')"
    exit 5
}

@"

guildos-daemon installed and paired.

Start it in this terminal with:
       "$daemonBin" run

Keep that process running to maintain the machine connection.

"@ | Write-Host
