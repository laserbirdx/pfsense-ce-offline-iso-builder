<#
.SYNOPSIS
    Builds fully offline installation media for pfSense CE (Windows entry point).

.DESCRIPTION
    Building the ISO requires xorriso, which has no native Windows build. This
    script finds a POSIX environment (WSL or MSYS2), installs one if needed,
    translates paths and runs the real builder there. The builder installs its
    own dependencies.

    You supply the Netgate Installer ISO (free):
    https://shop.netgate.com/products/netgate-installer

.PARAMETER Installer
    Path to the Netgate Installer ISO (.iso or .iso.gz). Searched for
    automatically if omitted.

.PARAMETER Version
    pfSense CE versions to build, e.g. 2.9.0,2.8.1

.PARAMETER Console
    vga | serial | both   (default: vga)

.PARAMETER Out
    Output directory (default: .\out)

.PARAMETER Mirror
    Package mirror directory (default: .\mirror)

.PARAMETER Memstick
    Also build a USB image (requires qemu; works best under WSL).

.PARAMETER KeepCache
    Keep the mirror when done, without asking.

.PARAMETER CleanCache
    Delete the mirror when done, without asking.

.PARAMETER Backend
    auto | wsl | msys2   (default: auto)

.PARAMETER ListVersions
    List the versions available on the server and exit.

.EXAMPLE
    .\pfsense-ce-offline-iso-builder.ps1 -ListVersions

.EXAMPLE
    .\pfsense-ce-offline-iso-builder.ps1 -Installer .\netgate-installer-v1.2-RELEASE-amd64.iso -Version 2.9.0 -Console both
#>
[CmdletBinding()]
param(
    [string]   $Installer,
    [string[]] $Version = @(),
    [ValidateSet('vga', 'serial', 'both')]
    [string]   $Console = 'vga',
    [string]   $Out     = '',
    [string]   $Mirror  = '',
    [switch]   $Memstick,
    [switch]   $KeepCache,
    [switch]   $CleanCache,
    [ValidateSet('auto', 'wsl', 'msys2')]
    [string]   $Backend = 'auto',
    [switch]   $ListVersions
)

$ErrorActionPreference = 'Stop'

function Write-Info { param($m) Write-Host "== $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "warning: $m" -ForegroundColor Yellow }
function Die        { param($m) Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# Script directory (works with spaces in the path)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir 'pfsense-ce-offline-iso-builder.sh'))) {
    Die "pfsense-ce-offline-iso-builder.sh not found next to this script ($ScriptDir). Copy the whole repository."
}

if (-not $Out)    { $Out    = Join-Path (Get-Location).Path 'out' }
if (-not $Mirror) { $Mirror = Join-Path (Get-Location).Path 'mirror' }

# ------------------------------------------------------------------ helpers
function Test-Command {
    param($Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Internet {
    try {
        $null = Invoke-WebRequest -Uri 'http://pkg01-atx.netgate.com/' -Method Head `
            -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        return $true
    } catch [System.Net.WebException] {
        # Any HTTP response (even an error status) means the network works.
        return $null -ne $_.Exception.Response
    } catch {
        return $false
    }
}

function Test-WslUsable {
    if (-not (Test-Command 'wsl.exe')) { return $false }
    try {
        # Is a distribution installed? (wsl -l -q prints nothing otherwise)
        $out = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $distros = @($out -split "`r?`n" |
            ForEach-Object { $_ -replace "`0", '' } |
            Where-Object { $_.Trim() -ne '' })
        return $distros.Count -gt 0
    } catch { return $false }
}

function Find-Msys2Bash {
    $candidates = @()
    if ($env:MSYS2_ROOT) { $candidates += (Join-Path $env:MSYS2_ROOT 'usr\bin\bash.exe') }
    $candidates += @(
        'C:\msys64\usr\bin\bash.exe',
        'C:\msys32\usr\bin\bash.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\msys64\usr\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-Wsl {
    Write-Info 'installing WSL (needs administrator rights and possibly a reboot)'
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Die @"
Installing WSL requires administrator rights.
Open PowerShell as Administrator and run:

    wsl --install -d Ubuntu

Run this script again after the installation and reboot.
"@
    }
    & wsl.exe --install -d Ubuntu
    Die 'WSL installed. Reboot and run this script again.'
}

function Install-Msys2 {
    if (-not (Test-Command 'winget')) {
        Die @"
MSYS2 not found and winget is not available.
Install it manually: https://www.msys2.org/
Then run this script again with -Backend msys2.
"@
    }
    Write-Info 'installing MSYS2 (winget)'
    & winget install --id MSYS2.MSYS2 --accept-package-agreements --accept-source-agreements
    $bash = Find-Msys2Bash
    if (-not $bash) { Die 'MSYS2 was installed but bash was not found; open a new terminal and try again.' }
    return $bash
}

# --------------------------------------------------------- internet check
if (Test-Internet) {
    Write-Info 'internet: OK (pkg01-atx.netgate.com reachable)'
} else {
    Write-Warn 'cannot reach pkg01-atx.netgate.com - no internet connection or the server is down'
    if ($ListVersions) { Die '-ListVersions needs an internet connection' }
    Write-Warn 'continuing offline: only versions already fully mirrored can be built'
}

# ------------------------------------------------------------------ backend
$useWsl   = $false
$msysBash = $null

switch ($Backend) {
    'wsl' {
        if (-not (Test-WslUsable)) { Install-Wsl }
        $useWsl = $true
    }
    'msys2' {
        $msysBash = Find-Msys2Bash
        if (-not $msysBash) { $msysBash = Install-Msys2 }
    }
    default {
        if (Test-WslUsable) {
            $useWsl = $true
        } else {
            $msysBash = Find-Msys2Bash
            if (-not $msysBash) {
                Write-Warn 'neither WSL nor MSYS2 was found.'
                Write-Host '  Building the ISO requires xorriso; one of the two is needed.'
                Write-Host '  [1] Install WSL   (recommended; administrator + reboot)'
                Write-Host '  [2] Install MSYS2 (via winget, no reboot)'
                $sel = Read-Host 'Choice [1/2]'
                if ($sel -eq '2') { $msysBash = Install-Msys2 } else { Install-Wsl }
            }
        }
    }
}

# --------------------------------------------------------- path translation
# Paths may contain spaces; every argument is passed as its own element, never
# through a shell command string.
function ConvertTo-WslPath {
    param([string]$WinPath)
    $full = [System.IO.Path]::GetFullPath($WinPath)
    # -e runs wslpath directly (no Linux shell), so spaces survive.
    $p = & wsl.exe -e wslpath -a -u $full 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $p) {
        # No wslpath: translate by hand, C:\x\y -> /mnt/c/x/y
        $drive = $full.Substring(0, 1).ToLower()
        $rest  = $full.Substring(2) -replace '\\', '/'
        return "/mnt/$drive$rest"
    }
    return ($p -replace "`r?`n", '').Trim()
}

function ConvertTo-MsysPath {
    param([string]$WinPath, [string]$Bash)
    $full = [System.IO.Path]::GetFullPath($WinPath)
    $cygpath = Join-Path (Split-Path -Parent $Bash) 'cygpath.exe'
    if (Test-Path -LiteralPath $cygpath) {
        $p = & $cygpath -u $full 2>$null
        if ($p) { return ($p -replace "`r?`n", '').Trim() }
    }
    $drive = $full.Substring(0, 1).ToLower()
    $rest  = $full.Substring(2) -replace '\\', '/'
    return "/$drive$rest"
}

function ConvertTo-PosixPath {
    param([string]$WinPath)
    if ($useWsl) { return ConvertTo-WslPath $WinPath }
    return ConvertTo-MsysPath $WinPath $msysBash
}

# ---------------------------------------------------------------- arguments
$shArgs = @()

$InstallerPage = 'https://shop.netgate.com/products/netgate-installer'

function Find-Installer {
    $dirs = @(
        (Get-Location).Path,
        $ScriptDir,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $hits = foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d -Filter 'netgate-installer*.iso*' -File -ErrorAction SilentlyContinue
    }
    $hits | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Show-InstallerHelp {
    $dirs = @(
        (Get-Location).Path,
        (Join-Path $env:USERPROFILE 'Downloads')
    ) | Select-Object -Unique
    Write-Host ''
    Write-Host 'The Netgate Installer ISO is required and could not be found.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  1. Download it for free from the page that just opened (requires a Netgate account):'
    Write-Host "     $InstallerPage"
    Write-Host '     Pick the AMD64 ISO; it must be v1.2-RELEASE or newer.'
    Write-Host ''
    Write-Host '  2. Put the downloaded file into one of these directories:'
    foreach ($d in $dirs) { Write-Host "     $d" }
    Write-Host ''
    Write-Host '  3. Run this command again (it will find the file by itself).'
    Write-Host ''
    Write-Host '  Alternatively, pass the path directly with -Installer.'
    Write-Host ''
}

if ($ListVersions) {
    $shArgs += '--list'
} else {
    if ($Installer -and -not (Test-Path -LiteralPath $Installer)) {
        Write-Warn "installer not found at the given path: $Installer"
        $Installer = ''
    }
    if (-not $Installer) {
        $found = Find-Installer
        if ($found) {
            Write-Info "found installer: $found"
            $Installer = $found
        } else {
            try {
                Start-Process $InstallerPage | Out-Null
                Write-Info 'opened the download page in your browser'
            } catch {
                Write-Warn 'could not open a browser; open the address manually'
            }
            Show-InstallerHelp
            Die 'no installer'
        }
    }
    if ($Version.Count -eq 0) { Die 'At least one version is required: -Version 2.9.0' }

    New-Item -ItemType Directory -Force -Path $Out, $Mirror | Out-Null

    $shArgs += @('-i', (ConvertTo-PosixPath $Installer))
    $shArgs += @('-o', (ConvertTo-PosixPath $Out))
    $shArgs += @('-M', (ConvertTo-PosixPath $Mirror))
    $shArgs += @('-c', $Console)
    if ($Memstick)   { $shArgs += '--memstick' }
    if ($KeepCache)  { $shArgs += '--keep-cache' }
    if ($CleanCache) { $shArgs += '--clean-cache' }
    $shArgs += '--'
    $shArgs += $Version
}

$builderPosix = ConvertTo-PosixPath (Join-Path $ScriptDir 'pfsense-ce-offline-iso-builder.sh')

if ($useWsl) {
    Write-Info 'running under WSL'
    # -e: no Linux shell in between, each argument arrives unchanged.
    & wsl.exe -e bash $builderPosix @shArgs
} else {
    Write-Info "running under MSYS2 ($msysBash)"
    $env:MSYSTEM = 'MSYS'
    $env:CHERE_INVOKING = '1'
    # A login shell sets up PATH; the script and its arguments are passed as
    # positional parameters, so spaces and quotes in paths are safe.
    & $msysBash -lc 'exec bash "$@"' bash $builderPosix @shArgs
}

$rc = $LASTEXITCODE
if ($rc -ne 0) { Die "build failed (exit code $rc)" }

if (-not $ListVersions) {
    Write-Info "done. output: $Out"
    Write-Host '   To write a USB stick use Rufus (DD mode) or balenaEtcher.'
}
