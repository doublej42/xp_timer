# build.ps1 - package xp_timer addon into a zip archive
# Usage: run this script from the addon directory (where xp_timer.lua and xp_timer.toc live).
# Requires 7z command-line tool (7z.exe) in PATH.

param(
    [string]$OutputZip = "xp_timer.zip"
)

# helper to write messages
function Write-Info {
    param([string]$msg)
    Write-Host "[INFO] $msg"
}

# ensure script runs from correct folder
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $base

# files to include
$files = @("xp_timer.lua", "xp_timer.toc")
foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-Error "Required file '$f' not found in current directory."
        exit 1
    }
}

# temporary staging directory
$tempDir = Join-Path $env:TEMP "xp_timer_build_$(Get-Random)"
if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Path $tempDir | Out-Null

# copy files into xp_timer subfolder
$staging = Join-Path $tempDir "xp_timer"
New-Item -ItemType Directory -Path $staging | Out-Null
foreach ($f in $files) {
    Copy-Item $f -Destination $staging
}

# produce zip using 7z
$sevenZip = "C:/Program Files/7-Zip/7z.exe"  # assume on PATH
if (-not (Get-Command $sevenZip -ErrorAction SilentlyContinue)) {
    Write-Error "7z executable not found in PATH. Please install 7-Zip or adjust PATH."
    exit 1
}

$zipPath = Join-Path $base $OutputZip
# remove existing archive if it exists
if (Test-Path $zipPath) {
    Write-Info "Removing existing archive '$zipPath'"
    Remove-Item $zipPath -Force
}

Write-Info "Creating zip file '$zipPath'..."
# -tzip type, -r recursive, archive name, include the xp_timer folder itself
& $sevenZip a -tzip -r $zipPath "$staging" | Out-Null

if (Test-Path $zipPath) {
    Write-Info "Archive created successfully."
} else {
    Write-Error "Failed to create archive."
    exit 1
}

# cleanup
Remove-Item -Recurse -Force $tempDir
Write-Info "Temporary files cleaned up."

Write-Info "Done."