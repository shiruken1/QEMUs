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
#   4b. Passwordless SSH: install an authorized public key with the correct
#       location + ACLs + encoding (the three things that trip everyone up on
#       Windows OpenSSH for admin accounts)
#   5. Network profile -> Private (per-profile firewall rules apply)
#   6. Firewall rule sshd on all profiles, port 22
#   7. Firewall rule for -AppPort (default 5005) on all profiles, matching the
#      hostfwd=tcp::5005-:5005 forward in win11.sh and win11_osx.sh (the latter
#      exposes it as APP_FORWARD / APP_HOST_PORT / APP_GUEST_PORT). This lets
#      `curl http://localhost:5005/` on the host reach a listener in the guest.
#   8. Power button policy -> Shut Down (so `system_powerdown` from the QEMU
#      monitor gracefully shuts the VM off instead of putting it to sleep)
#   9. W32Time -> Automatic + reliable NTP peers + hourly poll + immediate
#      resync (so the clock is right on every cold boot instead of drifting
#      until Windows eventually decides to sync)
#
# When it finishes: Shut Down the VM (NOT Restart -- ARM warm-reset is flaky),
# then from the Mac:
#   ./win11_osx.sh
#   ssh -p 2222 <your-windows-username>@127.0.0.1
#
# For bidirectional clipboard, also install SPICE Guest Tools separately from
# https://www.spice-space.org/download.html (spice-guest-tools-*.exe).

param(
    [string]$VirtioDrive = "D:",
    # TCP port to open in the guest firewall. Matches the QEMU host->guest
    # hostfwd forward set in win11.sh / win11_osx.sh. Default 5005 aligns with
    # hostfwd=tcp::5005-:5005 in both host scripts. Set to 0 to skip. Legacy
    # name -DebugPort is accepted as an alias for backward compatibility.
    [Alias('DebugPort')]
    [int]$AppPort = 5005,
    # Passwordless SSH: an OpenSSH public key to authorize. If empty, the script
    # auto-discovers a *.pub on the TOOLS delivery CD or next to this script.
    [string]$AuthorizedKey = "",
    [string]$AuthorizedKeyFile = ""
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

# --- 4b) Passwordless SSH: install an authorized public key ----------------

Section "4b) Passwordless SSH (install authorized key)"
# Windows OpenSSH has three foot-guns that all silently fall back to a password:
#   1. LOCATION: for accounts in the Administrators group the key must live in
#      C:\ProgramData\ssh\administrators_authorized_keys -- the per-user
#      %USERPROFILE%\.ssh\authorized_keys is IGNORED for admins.
#   2. ACLs: sshd refuses that admin file unless ONLY Administrators + SYSTEM can
#      access it (inheritance disabled).
#   3. ENCODING: the file must be ASCII/UTF-8 without a BOM; Set-Content/Add-Content
#      can emit UTF-16 or a BOM that sshd can't parse.
# This step handles all three. Provide the key via -AuthorizedKey / -AuthorizedKeyFile,
# or just drop your <name>.pub on the TOOLS CD (win11_osx.sh stages it there
# automatically) or next to this script.
$pubKey = $null
if ($AuthorizedKey.Trim()) {
    $pubKey = $AuthorizedKey.Trim()
    Info "Using key from -AuthorizedKey"
} elseif ($AuthorizedKeyFile -and (Test-Path $AuthorizedKeyFile)) {
    $pubKey = ([System.IO.File]::ReadAllText($AuthorizedKeyFile)).Trim()
    Info "Using key file: $AuthorizedKeyFile"
} else {
    # Auto-discover a *.pub on the TOOLS delivery CD or beside this script.
    $searchDirs = @()
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ($scriptDir) { $searchDirs += $scriptDir }
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq 'TOOLS' -and $_.DriveLetter } |
        ForEach-Object { $searchDirs += ("{0}:\" -f $_.DriveLetter) }
    foreach ($d in ($searchDirs | Select-Object -Unique)) {
        $cand = Get-ChildItem -Path $d -Filter *.pub -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($cand) {
            $pubKey = ([System.IO.File]::ReadAllText($cand.FullName)).Trim()
            Info "Auto-discovered key file: $($cand.FullName)"
            break
        }
    }
}

if (-not $pubKey) {
    Warn "No SSH public key found; leaving password auth in place."
    Info "Enable later by re-running with:  -AuthorizedKey 'ssh-ed25519 AAAA... you@mac'"
    Info "or drop your <name>.pub on the TOOLS drive (or beside this script) and re-run."
} elseif ($pubKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^\s]+|sk-[^\s]+)\s') {
    $preview = $pubKey.Substring(0, [Math]::Min(40, $pubKey.Length))
    Warn "That doesn't look like an OpenSSH public key; skipping. Got: '$preview...'"
} else {
    $isAdminUser = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdminUser) {
        $akFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        Info "Admin account -> using $akFile"
    } else {
        $akFile = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        Info "Standard account -> using $akFile"
    }
    $akDir = Split-Path -Parent $akFile
    if (-not (Test-Path $akDir)) { New-Item -ItemType Directory -Force -Path $akDir | Out-Null }

    # Merge idempotently, then write back as ASCII (no BOM) so sshd can parse it.
    $existing = @()
    if (Test-Path $akFile) {
        $existing = [System.IO.File]::ReadAllLines($akFile) | Where-Object { $_.Trim() -ne '' }
    }
    if ($existing -contains $pubKey) {
        OK "Key already authorized in $akFile"
    } else {
        $all = @($existing) + $pubKey
        [System.IO.File]::WriteAllText($akFile, ($all -join "`n") + "`n",
            (New-Object System.Text.ASCIIEncoding))
        OK "Key authorized in $akFile"
    }

    if ($isAdminUser) {
        # Required ACL: disable inheritance; grant only Administrators + SYSTEM.
        & icacls $akFile /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
        OK "ACLs locked to Administrators + SYSTEM (required for the admin keys file)"
    }
    Restart-Service sshd -ErrorAction SilentlyContinue
    Info "Test from the Mac:  ssh -i ~/.ssh/<your-private-key> -p 2222 $env:USERNAME@127.0.0.1"
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

# --- 6) Inbound firewall rule for -AppPort --------------------------------

Section "6) Firewall rule for TCP $AppPort (matches win11.sh/win11_osx.sh hostfwd)"
# The QEMU user-mode network stack forwards host :$AppPort -> guest :$AppPort
# via -netdev hostfwd (hostfwd=tcp::5005-:5005 in win11.sh; APP_FORWARD /
# APP_HOST_PORT / APP_GUEST_PORT in win11_osx.sh). Without a matching inbound
# rule Windows Defender Firewall silently drops those SYNs on the guest side,
# so `curl http://localhost:$AppPort/` (or `nc -vz 127.0.0.1 $AppPort`) from
# the host hangs. This rule opens it on all profiles; the Public/Private toggle
# above keeps it effective on the QEMU virtio-net link. Set -AppPort 0 to skip.
# The guest listener must bind to 0.0.0.0 (not 127.0.0.1) — QEMU's SLIRP NAT
# arrives on the virtio NIC, not on the guest's loopback interface.
if ($AppPort -gt 0) {
    $ruleName = "qemu-hostfwd-$AppPort"
    if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $ruleName `
            -DisplayName "QEMU hostfwd inbound (TCP $AppPort)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
            -LocalPort $AppPort -Profile Any | Out-Null
        OK "Inbound rule $ruleName created (TCP $AppPort, all profiles)"
    } else {
        Set-NetFirewallRule -Name $ruleName -Profile Any -Enabled True `
            -LocalPort $AppPort
        OK "Inbound rule $ruleName updated (TCP $AppPort, all profiles)"
    }
} else {
    Info "AppPort=0, skipping hostfwd firewall rule."
}

# --- 7) Power button policy -> Shut down ----------------------------------

Section "7) Power button -> Shut Down (so 'system_powerdown' works)"
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

# --- 8) W32Time -> Automatic + reliable NTP + immediate resync -----------

Section "8) W32Time (NTP) -> Automatic + reliable peers + resync now"
# Even with QEMU's -rtc base=localtime pinning the hardware clock to the Mac's
# wall time, W32Time by default is Manual/Trigger-start and only polls once a
# week -- so any drift (host sleep, HVF generic timer wobble, DST changeover)
# lingers for days. Configure it so:
#   * Service is Automatic (starts at every boot).
#   * Peers are Cloudflare + Google + pool.ntp.org (0x9 = client + special
#     interval, so SpecialPollInterval below is honored).
#   * SpecialPollInterval = 3600s (hourly) instead of the default weekly.
#   * Force one resync right now so this session is correct immediately.
try {
    Set-Service W32Time -StartupType Automatic
    Start-Service W32Time -ErrorAction SilentlyContinue

    $peers = "time.cloudflare.com,0x9 time.google.com,0x9 pool.ntp.org,0x9"
    & w32tm /config /manualpeerlist:$peers /syncfromflags:manual /reliable:yes /update | Out-Host

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" `
        -Name "SpecialPollInterval" -Type DWord -Value 3600
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" `
        -Name "MaxPosPhaseCorrection" -Type DWord -Value 0xFFFFFFFF
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" `
        -Name "MaxNegPhaseCorrection" -Type DWord -Value 0xFFFFFFFF

    Restart-Service W32Time -ErrorAction SilentlyContinue
    & w32tm /resync /nowait | Out-Host

    $status = & w32tm /query /status 2>$null
    if ($status) { $status | ForEach-Object { Info $_ } }
    OK "W32Time configured (Automatic, hourly poll, resync issued)"
} catch {
    Warn "W32Time configuration failed: $($_.Exception.Message)"
}

# --- Summary --------------------------------------------------------------

Section "Summary"
$viogpudoStatus = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                  Where-Object { $_.FriendlyName -like '*VirtIO*' } |
                  Select-Object -First 1 -ExpandProperty Status
$vgpuSvcObj = Get-Service | Where-Object { $_.Name -like '*vgpu*' } | Select-Object -First 1
$sshdSvc    = Get-Service sshd -ErrorAction SilentlyContinue
$adminAk    = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$userAk     = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$keyState   = if ((Test-Path $adminAk) -and (Get-Content $adminAk -ErrorAction SilentlyContinue)) { "yes (admin file)" }
              elseif ((Test-Path $userAk) -and (Get-Content $userAk -ErrorAction SilentlyContinue)) { "yes (user file)" }
              else { "no (password only)" }

Info ("viogpudo (Display): {0}" -f ($viogpudoStatus, '(unknown)' -ne $null | Select-Object -First 1))
Info ("vgpusrv service   : {0} / {1}" -f $vgpuSvcObj.Name, $vgpuSvcObj.Status)
Info ("sshd service      : {0} / {1}" -f $sshdSvc.Status, $sshdSvc.StartType)
Info ("passwordless SSH  : {0}" -f $keyState)

Write-Host ""
Write-Host "Now SHUT DOWN Windows (Start -> Power -> Shut down) and re-run" -ForegroundColor Cyan
Write-Host "./win11_osx.sh on the Mac. In-guest Restart is unreliable on ARM;" -ForegroundColor Cyan
Write-Host "shut down + relaunch is the reliable cycle." -ForegroundColor Cyan
Write-Host ""
Write-Host "After boot (allow 60-120s for viogpudo/DWM to settle after mode changes):" -ForegroundColor Cyan
Write-Host "  ssh -p 2222 $env:USERNAME@127.0.0.1" -ForegroundColor Green
Write-Host ""
Write-Host "For bidirectional clipboard (cocoa <-> Windows), also install:" -ForegroundColor Cyan
Write-Host "  https://www.spice-space.org/download.html -> spice-guest-tools-*.exe" -ForegroundColor Cyan
Write-Host "then reboot; Task Manager should show vdagent.exe alongside vdservice.exe." -ForegroundColor Cyan
