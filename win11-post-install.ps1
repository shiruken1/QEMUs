# Windows 11 ARM64 post-install setup for QEMU/HVF on macOS.
#
# Run once inside the guest, from an Admin PowerShell, after Windows OOBE:
#   powershell -ExecutionPolicy Bypass -File .\win11-post-install.ps1
#
# Prerequisites in the guest:
#   - virtio-win.iso is mounted (default: D:) -- ./win11_osx.sh already attaches it.
#   - Network is up (uses Add-WindowsCapability which needs the Microsoft servers).
#
# What this does (idempotent; safe to re-run):
#   1. VirtIO Serial driver (vioserial)                -> host clipboard bridge
#   2. VirtIO GPU DOD driver (viogpudo)                -> primary display device
#   3. VioGpu Resolution Service (vgpusrv + viogpuap)  -> dynamic resize
#   4. OpenSSH Server                                  -> headless access from Mac
#      (includes the wuauserv/bits restart trick that unblocks Add-WindowsCapability
#       when the Windows Update servicing stack has silently jammed)
#   5. Network profile -> Private (per-profile firewall rules apply)
#   6. Firewall rule sshd on all profiles, port 22
#   7. Power button policy -> Shut Down (so `system_powerdown` from the QEMU
#      monitor gracefully shuts the VM off instead of putting it to sleep)
#
# When it finishes: Shut Down the VM (NOT Restart -- ARM warm-reset is flaky),
# then from the Mac:
#   ./win11_osx.sh
#   ssh -p 12222 <your-windows-username>@127.0.0.1
#
# For bidirectional clipboard, also install SPICE Guest Tools separately from
# https://www.spice-space.org/download.html (spice-guest-tools-*.exe).

param(
    [string]$VirtioDrive = "D:"
)

# Continue past individual failures so we can complete as much setup as possible.
$ErrorActionPreference = "Continue"

function Section($title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
}
function Info($msg) { Write-Host $msg -ForegroundColor Gray }
function OK($msg)   { Write-Host "OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red }

# --- Preflight -------------------------------------------------------------

Section "Preflight"
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail "Must be run from an ADMIN PowerShell (Right-click Terminal -> Run as administrator)."
    exit 1
}
Info "Edition:      $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID)"
Info "Architecture: $env:PROCESSOR_ARCHITECTURE"
Info "VirtIO drive: $VirtioDrive"
if (-not (Test-Path $VirtioDrive)) {
    Fail "$VirtioDrive not found. Mount virtio-win.iso and rerun."
    exit 1
}

# --- 1) vioserial driver (needed for host<->guest clipboard) ---------------

Section "1) VirtIO Serial driver (vioserial)"
$vioserialInf = Join-Path $VirtioDrive "vioserial\w11\ARM64\vioser.inf"
if (Test-Path $vioserialInf) {
    pnputil /add-driver $vioserialInf /install | Out-Host
    OK "vioserial installed from $vioserialInf"
} else {
    Warn "vioserial INF not found at $vioserialInf"
}

# --- 2) viogpudo driver (Display Only Driver for virtio-gpu-pci) -----------

Section "2) VirtIO GPU DOD driver (viogpudo)"
$viogpudoInf = Join-Path $VirtioDrive "viogpudo\w11\ARM64\viogpudo.inf"
if (Test-Path $viogpudoInf) {
    pnputil /add-driver $viogpudoInf /install | Out-Host
    OK "viogpudo installed from $viogpudoInf"
} else {
    Warn "viogpudo INF not found at $viogpudoInf"
}

# --- 3) vgpusrv (VioGpu Resolution Service) --------------------------------

Section "3) VioGpu Resolution Service (dynamic display resize)"
$vgpusrv  = Join-Path $VirtioDrive "viogpudo\w11\ARM64\vgpusrv.exe"
$viogpuap = Join-Path $VirtioDrive "viogpudo\w11\ARM64\viogpuap.exe"
if ((Test-Path $vgpusrv) -and (Test-Path $viogpuap)) {
    Copy-Item $vgpusrv, $viogpuap -Destination "$env:WINDIR\System32\" -Force
    Push-Location "$env:WINDIR\System32"
    # `vgpusrv.exe -u` is a no-op if not installed; running it first makes -i idempotent.
    & .\vgpusrv.exe -u 2>$null | Out-Null
    & .\vgpusrv.exe -i | Out-Host
    Pop-Location
    $svc = Get-Service | Where-Object { $_.Name -like '*vgpu*' } | Select-Object -First 1
    if ($svc) {
        Set-Service -Name $svc.Name -StartupType Automatic
        Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
        OK "vgpusrv installed and started (service: $($svc.Name))"
    } else {
        Warn "vgpusrv -i ran but no matching service found"
    }
} else {
    Warn "vgpusrv/viogpuap not found under $VirtioDrive\viogpudo\w11\ARM64\"
}

# --- 4) OpenSSH Server (headless access when the display is dead) ----------

Section "4) OpenSSH Server"
# The wuauserv+bits restart works around a common failure mode where
# Add-WindowsCapability silently stalls or fails because the Windows Update
# servicing stack is wedged. Bouncing both unblocks it.
Info "Cycling wuauserv + bits so Add-WindowsCapability doesn't stall..."
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service bits    -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue
Start-Service bits    -ErrorAction SilentlyContinue

try {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" |
           Select-Object -First 1
    if (-not $cap) {
        Fail "No OpenSSH.Server capability found (Add-WindowsCapability catalog empty)"
    } elseif ($cap.State -ne 'Installed') {
        Info "Installing $($cap.Name)..."
        Add-WindowsCapability -Online -Name $cap.Name | Out-Host
        OK "OpenSSH.Server installed"
    } else {
        OK "OpenSSH.Server already installed"
    }
} catch {
    Fail "Add-WindowsCapability failed: $($_.Exception.Message)"
}

if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd -ErrorAction SilentlyContinue

    if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort 22 -Profile Any | Out-Null
        OK "sshd firewall rule created (port 22, all profiles)"
    } else {
        Set-NetFirewallRule -Name sshd -Profile Any -Enabled True
        OK "sshd firewall rule updated (all profiles, enabled)"
    }

    $svc = Get-Service sshd
    OK "sshd: $($svc.Status) / $($svc.StartType)"
} else {
    Fail "sshd service missing after Add-WindowsCapability"
}

# --- 5) Network profile -> Private ----------------------------------------

Section "5) Network profile -> Private"
# On a fresh install Windows classifies the QEMU virtio-net link as Public,
# which blocks most inbound rules. Flipping to Private makes the sshd rule
# actually take effect on this connection.
try {
    Get-NetConnectionProfile | ForEach-Object {
        if ($_.NetworkCategory -ne 'Private') {
            Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
            OK "Interface $($_.InterfaceAlias) -> Private"
        } else {
            Info "Interface $($_.InterfaceAlias) already Private"
        }
    }
} catch {
    Warn "Could not set network profile: $($_.Exception.Message)"
}

# --- 6) Power button policy -> Shut down ----------------------------------

Section "6) Power button -> Shut Down (so 'system_powerdown' works)"
# powercfg action codes: 0=Do Nothing, 1=Sleep, 2=Hibernate, 3=Shut Down.
# Win11 defaults the ACPI power button to Sleep, so the QEMU monitor's
# `system_powerdown` (which emulates a physical power button press) just
# suspends the guest instead of powering it off. We want a clean shutdown.
try {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
    powercfg /setactive SCHEME_CURRENT
    OK "Power button will now Shut Down (system_powerdown = clean poweroff)"
} catch {
    Warn "powercfg failed: $($_.Exception.Message)"
}

# --- Summary --------------------------------------------------------------

Section "Summary"
$viogpudoStatus = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                  Where-Object { $_.FriendlyName -like '*VirtIO*' } |
                  Select-Object -First 1 -ExpandProperty Status
$vgpuSvcObj = Get-Service | Where-Object { $_.Name -like '*vgpu*' } | Select-Object -First 1
$sshdSvc    = Get-Service sshd -ErrorAction SilentlyContinue

Info ("viogpudo (Display): {0}" -f ($viogpudoStatus, '(unknown)' -ne $null | Select-Object -First 1))
Info ("vgpusrv service   : {0} / {1}" -f $vgpuSvcObj.Name, $vgpuSvcObj.Status)
Info ("sshd service      : {0} / {1}" -f $sshdSvc.Status, $sshdSvc.StartType)

Write-Host ""
Write-Host "Now SHUT DOWN Windows (Start -> Power -> Shut down) and re-run" -ForegroundColor Cyan
Write-Host "./win11_osx.sh on the Mac. In-guest Restart is unreliable on ARM;" -ForegroundColor Cyan
Write-Host "shut down + relaunch is the reliable cycle." -ForegroundColor Cyan
Write-Host ""
Write-Host "After boot (allow 60-120s for viogpudo/DWM to settle after mode changes):" -ForegroundColor Cyan
Write-Host "  ssh -p 12222 $env:USERNAME@127.0.0.1" -ForegroundColor Green
Write-Host ""
Write-Host "For bidirectional clipboard (cocoa <-> Windows), also install:" -ForegroundColor Cyan
Write-Host "  https://www.spice-space.org/download.html -> spice-guest-tools-*.exe" -ForegroundColor Cyan
Write-Host "then reboot; Task Manager should show vdagent.exe alongside vdservice.exe." -ForegroundColor Cyan
