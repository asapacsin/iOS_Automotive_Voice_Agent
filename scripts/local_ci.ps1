# Local CI (owner rule 2026-10-27): no paid GitHub runners and no emulator.
#  1. gates: scripts/gates/run_all.sh in WSL Ubuntu (Swift 6.0.3, same as the old core-linux job)
#  2. phone: scripts/device/phone_check.py on the plugged-in iPhone (optionally installs an .ipa first)
# Usage:  powershell -File scripts\local_ci.ps1 [-SkipGates] [-SkipPhone] [-Ipa D:\ndipa\x\NovaDrive.ipa]
param([switch]$SkipGates, [switch]$SkipPhone, [string]$Ipa = "")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path
$fail = $false

if (-not $SkipGates) {
    Write-Host "== gates (WSL)"
    # WSL inherits a Windows proxy on 127.0.0.1 it cannot reach; go direct.
    wsl -d Ubuntu-22.04 --cd "$root" -- env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY bash scripts/gates/run_all.sh
    if ($LASTEXITCODE -ne 0) { Write-Host "gates: FAIL"; $fail = $true }
}

if (-not $SkipPhone) {
    Write-Host "== phone check"
    $args2 = @("$root\scripts\device\phone_check.py")
    if ($Ipa) { $args2 += @("--ipa", $Ipa) }
    python @args2
    if ($LASTEXITCODE -ne 0) { Write-Host "phone: FAIL"; $fail = $true }
}

if ($fail) { Write-Host "local ci: FAIL"; exit 1 }
Write-Host "local ci: PASS"
