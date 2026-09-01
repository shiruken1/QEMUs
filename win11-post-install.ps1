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
#  10. Scheduled task 'LaunchRevit2025' (idempotent, /IT + /RU <user>) so
#      `schtasks /Run /TN LaunchRevit2025` over SSH launches Revit on the
#      user's interactive desktop instead of the invisible Session 0 that
#      OpenSSH puts you in. Pass -RevitExe "" to skip if Revit isn't
#      installed on this VM.
#  11. Self-signed CodeSigningCert in CurrentUser\My, exported to
#      <profile>\cert\buildtrue-dev-codesign.pfx (private) + .cer (public),
#      with the .cer imported into LocalMachine\Root + \TrustedPublisher.
#      Lets the dev pipeline Authenticode-sign the BuildTrue add-in DLLs
#      so Revit stops nagging about unsigned add-ins without needing
#      per-GUID CodeSigning DWORDs. This cert is DEV-ONLY and never leaves
#      the VM; the .pfx password defaults to "changeme-dev-only". Pass
#      -InstallCodeSignCert $false to skip, or override the artifact
#      locations with -CodeSignPfxPath / -CodeSignCerPath.
#  12. SSH remote admin: LocalAccountTokenFilterPolicy=1 (full admin token
#      for local accounts over OpenSSH instead of UAC's filtered "deny only"
#      token) + gsudo (explicit sudo-style elevation fallback). Pass
#      -InstallRemoteAdminSsh $false to skip. Reboot required for the
#      registry change to take effect.
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
    [string]$AuthorizedKeyFile = "",
    # Scheduled task shim so `ssh_vm 'schtasks /Run /TN LaunchRevit2025'`
    # can launch Revit on the interactive desktop (Session 0 vs interactive
    # session workaround for Windows OpenSSH). Pass -RevitExe "" to skip.
    [string]$RevitExe = "C:\Program Files\Autodesk\Revit 2025\Revit.exe",
    [string]$RevitTaskName = "LaunchRevit2025",
    # Dev-only self-signed code-signing cert (section 11). Set to $false
    # to skip the whole section, e.g. on a VM that doesn't do plugin dev.
    [bool]$InstallCodeSignCert    = $true,
    [string]$CodeSignSubject      = "CN=BuildTrue Dev Code Signing, O=BuildTrue Solutions, OU=Internal Dev",
    [string]$CodeSignFriendlyName = "BuildTrue Dev Code Signing",
    [int]$CodeSignYears           = 5,
    # Blank = default to <profile>\cert\buildtrue-dev-codesign.{pfx,cer} at
    # run time. The <profile>\cert directory is created if it doesn't exist.
    [string]$CodeSignPfxPath      = "",
    [string]$CodeSignCerPath      = "",
    # Throw-away password protecting the .pfx on disk. The cert is dev-only
    # and never leaves the VM; override with -CodeSignPfxPassword if you
    # want something stronger.
    [string]$CodeSignPfxPassword  = "changeme-dev-only",
    # SSH remote admin: LocalAccountTokenFilterPolicy + gsudo (section 12).
    # The registry change needs a reboot; gsudo works immediately as fallback.
    [bool]$InstallRemoteAdminSsh  = $true
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

    # QEMU user-mode networking (gpu.sh / win11.sh hostfwd :2222->:22) delivers
    # forwarded SSH to the virtio NIC (10.0.2.x), not loopback. If sshd only
    # listens on 127.0.0.1, the service shows Running but host SSH gets
    # "connection refused". Some Win11 builds ship sshd_config with loopback-only
    # ListenAddress; comment those out so sshd binds all interfaces again.
    $sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (Test-Path $sshdConfig) {
        $cfgLines = [System.IO.File]::ReadAllLines($sshdConfig)
        $cfgChanged = $false
        $newCfg = foreach ($line in $cfgLines) {
            if ($line -match '^\s*ListenAddress\s+(127\.|::1)') {
                $cfgChanged = $true
                "# $line  # disabled by win11-post-install: QEMU hostfwd uses virtio NIC"
            } else {
                $line
            }
        }
        if ($cfgChanged) {
            $bak = "$sshdConfig.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
            Copy-Item -LiteralPath $sshdConfig -Destination $bak -Force
            [System.IO.File]::WriteAllLines($sshdConfig, $newCfg)
            Restart-Service sshd -ErrorAction SilentlyContinue
            OK "sshd_config: removed loopback-only ListenAddress (backup: $bak)"
        } else {
            Info "sshd_config: no loopback-only ListenAddress to fix"
        }
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

# --- 10) Scheduled task -> launch Revit on the interactive desktop --------

Section "10) Scheduled task '$RevitTaskName' (SSH -> interactive-desktop Revit)"
# Windows OpenSSH drops incoming sessions into a non-interactive session that
# is isolated from the logged-on user's desktop (aka Session 0 isolation).
# So `ssh_vm 'cmd /c start "" "C:\...\Revit.exe"'` launches Revit as a hidden
# process in the SSH session -- its window can never render on the visible
# desktop and it usually self-exits shortly after startup. Task Manager on
# the console shows no Revit at all.
#
# The standard workaround is a scheduled task registered with:
#   /RU <user>  -- run as the interactively-logged-on user
#   /IT         -- use that user's *interactive* token (visible on desktop)
#   /SC ONCE /ST 00:00 -- dummy past-time trigger so the task exists but
#                         never fires on its own; only responds to /Run
#   /F          -- overwrite any prior definition (idempotent re-runs)
#
# From the Mac:
#   ssh -p 2222 <user>@127.0.0.1 'schtasks /Run /TN "LaunchRevit2025"'
# The user must be logged in on the VM console for /IT to have a session
# to run in; if nobody's logged in, /Run returns success but nothing appears.
if (-not $RevitExe) {
    Info "-RevitExe is empty; skipping Revit scheduled task."
} elseif (-not (Test-Path $RevitExe)) {
    Warn "Revit not found at '$RevitExe'; skipping scheduled task."
    Info "Install Revit and re-run, or pass -RevitExe '<full-path-to-Revit.exe>'."
} else {
    try {
        # schtasks parses /TR as a single string; wrap the exe path in quotes
        # so its spaces don't get split into a phantom argument. /F makes
        # this call idempotent on re-run.
        $trArg = '"' + $RevitExe + '"'
        & schtasks /Create /TN $RevitTaskName /TR $trArg `
            /SC ONCE /ST 00:00 /RU $env:USERNAME /IT /F 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) {
            OK "Scheduled task '$RevitTaskName' registered (RU=$env:USERNAME, IT, launches $RevitExe)"
            Info ("Trigger from Mac:  ssh -p 2222 {0}@127.0.0.1 'schtasks /Run /TN `"{1}`"'" `
                -f $env:USERNAME, $RevitTaskName)
        } else {
            Warn "schtasks /Create exited with code $LASTEXITCODE"
        }
    } catch {
        Warn "schtasks /Create failed: $($_.Exception.Message)"
    }
}

# --- 11) Self-signed code-signing cert + machine trust roots --------------

Section "11) Code-signing cert '$CodeSignFriendlyName' (dev only)"
# Creates a self-signed CodeSigningCert in CurrentUser\My so the dev build
# pipeline can Authenticode-sign the BuildTrue add-in DLLs, exports it as
# .pfx (private key, password-protected) + .cer (public only), then imports
# the .cer into LocalMachine\Root and \TrustedPublisher. Once the DLLs are
# signed with this cert, Revit's "Security -- Unsigned Add-In" dialog stops
# firing entirely, without needing per-GUID entries under
# HKCU\...\Autodesk Revit 2025\CodeSigning.
#
# NEVER SHIP THIS CERT. It has no real chain of trust -- only the
# LocalMachine store on this VM trusts it. The default .pfx password
# ("changeme-dev-only") is intentionally weak; override with
# -CodeSignPfxPassword if you care.
if (-not $InstallCodeSignCert) {
    Info "-InstallCodeSignCert = `$false; skipping."
} else {
    try {
        # Default the cert artifacts to <profile>\cert\, and make sure that
        # directory exists before we try to Export-*Certificate into it.
        # New-Item -Force is a no-op if the folder is already there.
        $certDir = Join-Path $env:USERPROFILE 'cert'
        if (-not $CodeSignPfxPath) { $CodeSignPfxPath = Join-Path $certDir 'buildtrue-dev-codesign.pfx' }
        if (-not $CodeSignCerPath) { $CodeSignCerPath = Join-Path $certDir 'buildtrue-dev-codesign.cer' }
        $pfxParent = Split-Path -Parent $CodeSignPfxPath
        $cerParent = Split-Path -Parent $CodeSignCerPath
        foreach ($dir in @($pfxParent, $cerParent) | Select-Object -Unique) {
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                Info "Created directory $dir"
            }
        }

        # Reuse an existing (non-expired) cert with the same FriendlyName so
        # repeated runs don't pile up throwaway self-signed certs in the
        # store. Match on FriendlyName rather than Subject because Subject
        # formatting can vary subtly across PowerShell versions.
        $cert = Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -eq $CodeSignFriendlyName -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending | Select-Object -First 1

        if ($cert) {
            Info "Reusing existing cert (Thumbprint $($cert.Thumbprint), expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
        } else {
            Info "Creating new self-signed cert '$CodeSignFriendlyName'..."
            $cert = New-SelfSignedCertificate `
                -Type CodeSigningCert `
                -Subject $CodeSignSubject `
                -KeyUsage DigitalSignature `
                -FriendlyName $CodeSignFriendlyName `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -NotAfter (Get-Date).AddYears($CodeSignYears) `
                -KeyExportPolicy Exportable `
                -KeySpec Signature `
                -KeyLength 2048 `
                -HashAlgorithm SHA256 `
                -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")  # EKU: Code Signing (1.3.6.1.5.5.7.3.3)
            OK "Created cert (Thumbprint $($cert.Thumbprint), expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
        }

        # Always (re-)export so the .pfx/.cer on disk match what's in the
        # store. -Force overwrites without prompting. The .pfx contains the
        # private key protected by $CodeSignPfxPassword; the .cer is
        # public-key only and is what gets imported into machine trust.
        $pwd = ConvertTo-SecureString -String $CodeSignPfxPassword -Force -AsPlainText
        Export-PfxCertificate -Cert $cert -FilePath $CodeSignPfxPath -Password $pwd -Force | Out-Null
        Export-Certificate    -Cert $cert -FilePath $CodeSignCerPath -Force | Out-Null
        OK "Exported .pfx -> $CodeSignPfxPath"
        OK "Exported .cer -> $CodeSignCerPath"

        # Import the public cert into LocalMachine\Root (so the OS trusts
        # the CA at all) and LocalMachine\TrustedPublisher (so signed
        # binaries from this publisher run without a per-launch prompt).
        # Skip when a cert with the same thumbprint is already there so
        # re-runs stay clean.
        foreach ($storeName in @('Root','TrustedPublisher')) {
            $storePath = "Cert:\LocalMachine\$storeName"
            $existing  = Get-ChildItem $storePath -ErrorAction SilentlyContinue |
                         Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
            if ($existing) {
                Info "Cert already in LocalMachine\$storeName"
            } else {
                Import-Certificate -FilePath $CodeSignCerPath `
                    -CertStoreLocation $storePath | Out-Null
                OK "Imported into LocalMachine\$storeName"
            }
        }

        Info ""
        Info "Sign a DLL from PowerShell:"
        Info "  Set-AuthenticodeSignature -FilePath <path.dll> -Certificate (Get-Item Cert:\CurrentUser\My\$($cert.Thumbprint))"
        Info "Or from a build script with signtool:"
        Info "  signtool sign /fd SHA256 /f `"$CodeSignPfxPath`" /p `"$CodeSignPfxPassword`" <path.dll>"
    } catch {
        Warn "Code-signing cert setup failed: $($_.Exception.Message)"
    }
}

# --- 12) SSH remote admin (full token over SSH + gsudo) -------------------

Section "12) SSH remote admin (LocalAccountTokenFilterPolicy + gsudo)"
# OpenSSH drops admin-group members into a UAC-filtered token: the
# Administrators SID shows up as "Group used for deny only", so remote
# shells can't install drivers, touch HKLM, or run elevated scripts.
# LocalAccountTokenFilterPolicy=1 gives local accounts the full admin
# token on network logons (including sshd). Safe for an isolated dev VM;
# do NOT enable on a machine exposed to untrusted networks.
# gsudo is installed as a belt-and-suspenders fallback (`gsudo powershell`,
# `gsudo powershell -File script.ps1`) and works before the reboot.
$remoteAdminPolicyNeedsReboot = $false
if (-not $InstallRemoteAdminSsh) {
    Info "-InstallRemoteAdminSsh = `$false; skipping."
} else {
    try {
        $policyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $currentPolicy = (Get-ItemProperty -Path $policyPath `
            -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
        if ($currentPolicy -eq 1) {
            OK "LocalAccountTokenFilterPolicy already 1 (full admin token over SSH)"
        } else {
            New-ItemProperty -Path $policyPath -Name LocalAccountTokenFilterPolicy `
                -Value 1 -PropertyType DWORD -Force | Out-Null
            $remoteAdminPolicyNeedsReboot = $true
            OK "LocalAccountTokenFilterPolicy=1 (takes effect after reboot)"
        }

        if (Get-Command gsudo -ErrorAction SilentlyContinue) {
            OK ("gsudo already on PATH -> {0}" -f (Get-Command gsudo).Source)
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            Info "Installing gsudo via winget..."
            & winget install --id gerardog.gsudo -e `
                --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
            # 0 = installed; -1978335189 = already installed.
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
                OK "gsudo installed (or already present via winget)"
            } else {
                Warn "winget install gsudo exited with code $LASTEXITCODE"
                Info "Install manually: https://github.com/gerardog/gsudo/releases"
            }
        } else {
            Warn "winget not found; install gsudo manually from https://github.com/gerardog/gsudo"
        }

        # winget updates Machine/User PATH; refresh so the summary can see gsudo.
        $env:Path = [string]::Join(';', @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine')
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ))
        if (Get-Command gsudo -ErrorAction SilentlyContinue) {
            OK ("gsudo on PATH -> {0}" -f (Get-Command gsudo).Source)
        } else {
            Info "gsudo not visible in this session yet; new shells (or reboot) will pick it up."
        }
    } catch {
        Warn "SSH remote admin setup failed: $($_.Exception.Message)"
    }
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

$revitTask     = Get-ScheduledTask -TaskName $RevitTaskName -ErrorAction SilentlyContinue
$revitTaskState = if ($revitTask) { "registered ($($revitTask.State))" } else { "not registered" }
$codeSignCert  = Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FriendlyName -eq $CodeSignFriendlyName } |
                 Sort-Object NotAfter -Descending | Select-Object -First 1
$codeSignState = if ($codeSignCert) {
                    "$($codeSignCert.Thumbprint.Substring(0,12))... expires $($codeSignCert.NotAfter.ToString('yyyy-MM-dd'))"
                 } else { "not installed" }
$policyPathSummary = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$remoteAdminPolicy = (Get-ItemProperty -Path $policyPathSummary `
    -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
$remoteAdminState  = if ($remoteAdminPolicy -eq 1) { "enabled (reboot if just set)" } else { "disabled" }
$gsudoCmd          = Get-Command gsudo -ErrorAction SilentlyContinue
$gsudoState        = if ($gsudoCmd) { "yes -> $($gsudoCmd.Source)" } else { "no" }

Info ("viogpudo (Display) : {0}" -f ($viogpudoStatus, '(unknown)' -ne $null | Select-Object -First 1))
Info ("vgpusrv service    : {0} / {1}" -f $vgpuSvcObj.Name, $vgpuSvcObj.Status)
Info ("sshd service       : {0} / {1}" -f $sshdSvc.Status, $sshdSvc.StartType)
Info ("passwordless SSH   : {0}" -f $keyState)
Info ("SSH remote admin   : {0}" -f $remoteAdminState)
Info ("gsudo              : {0}" -f $gsudoState)
Info ("Revit launch task  : {0} -> {1}" -f $RevitTaskName, $revitTaskState)
Info ("Dev code-sign cert : {0} -> {1}" -f $CodeSignFriendlyName, $codeSignState)

Write-Host ""
Write-Host "Now SHUT DOWN Windows (Start -> Power -> Shut down) and re-run" -ForegroundColor Cyan
Write-Host "./win11_osx.sh on the Mac. In-guest Restart is unreliable on ARM;" -ForegroundColor Cyan
Write-Host "shut down + relaunch is the reliable cycle." -ForegroundColor Cyan
Write-Host ""
Write-Host "After boot (allow 60-120s for viogpudo/DWM to settle after mode changes):" -ForegroundColor Cyan
Write-Host "  ssh -p 2222 $env:USERNAME@127.0.0.1" -ForegroundColor Green
Write-Host ""
if ($remoteAdminPolicyNeedsReboot) {
    Write-Host "SSH remote admin: LocalAccountTokenFilterPolicy was just set -> reboot required." -ForegroundColor Yellow
}
Write-Host "Verify admin elevation over SSH (expect Enabled, NOT 'deny only'):" -ForegroundColor Cyan
Write-Host "  whoami /groups | findstr Administrators" -ForegroundColor Green
Write-Host ""
Write-Host "Interactive admin PowerShell over SSH (after reboot):" -ForegroundColor Cyan
Write-Host "  powershell" -ForegroundColor Green
Write-Host "Or use gsudo immediately (works even before reboot):" -ForegroundColor Cyan
Write-Host "  gsudo powershell" -ForegroundColor Green
Write-Host ""
Write-Host "Run an admin script from the Mac:" -ForegroundColor Cyan
Write-Host ("  ssh -p 2222 {0}@127.0.0.1 'powershell -ExecutionPolicy Bypass -File C:\path\script.ps1'" -f $env:USERNAME) -ForegroundColor Green
Write-Host "Or with gsudo (explicit elevation):" -ForegroundColor Cyan
Write-Host ("  ssh -p 2222 {0}@127.0.0.1 'gsudo powershell -ExecutionPolicy Bypass -File C:\path\script.ps1'" -f $env:USERNAME) -ForegroundColor Green
Write-Host ""
Write-Host "For bidirectional clipboard (cocoa <-> Windows), also install:" -ForegroundColor Cyan
Write-Host "  https://www.spice-space.org/download.html -> spice-guest-tools-*.exe" -ForegroundColor Cyan
Write-Host "then reboot; Task Manager should show vdagent.exe alongside vdservice.exe." -ForegroundColor Cyan
Write-Host ""
Write-Host "To launch Revit on the VM's desktop from the Mac over SSH:" -ForegroundColor Cyan
Write-Host ("  ssh -p 2222 {0}@127.0.0.1 'schtasks /Run /TN `"{1}`"'" -f $env:USERNAME, $RevitTaskName) -ForegroundColor Green
Write-Host "(You must be logged in on the VM console; /IT needs an interactive session.)" -ForegroundColor Cyan
