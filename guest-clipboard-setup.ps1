# Run inside the Windows 11 ARM64 VM (Admin PowerShell).
# Diagnoses and installs VirtIO serial (required for host clipboard) + checks vdagent.
#
# Usage (virtio-win.iso mounted as D:):
#   powershell -ExecutionPolicy Bypass -File \\path\to\guest-clipboard-setup.ps1

$ErrorActionPreference = "Stop"
$VirtioDrive = "D:"

Write-Host "=== QEMU clipboard guest setup ===" -ForegroundColor Cyan
Write-Host "Edition: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID)"
Write-Host ""

$inf = Join-Path $VirtioDrive "vioserial\w11\ARM64\vioser.inf"
if (-not (Test-Path $inf)) {
    Write-Host "ERROR: virtio-win not found at $VirtioDrive (expected $inf)" -ForegroundColor Red
    exit 1
}

Write-Host "Installing VirtIO serial driver from $inf ..."
pnputil /add-driver $inf /install
Write-Host ""

Write-Host "VirtIO serial ports (need com.redhat.spice.0):"
Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue |
    Format-Table -AutoSize FriendlyName, InstanceId, Status
Write-Host ""

$portPath = "\\.\Global\com.redhat.spice.0"
Write-Host "Testing named pipe $portPath ..."
try {
    $fs = [System.IO.File]::Open($portPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    $fs.Close()
    Write-Host "OK: virtio serial port is present." -ForegroundColor Green
} catch {
    Write-Host "MISSING: $portPath ($($_.Exception.Message))" -ForegroundColor Yellow
    Write-Host "Reboot Windows, then re-run this script. Until the port exists, clipboard cannot work."
}

Write-Host ""
Write-Host "SPICE agent processes (need vdagent.exe in your session):"
Get-Process -Name vdservice, vdagent -ErrorAction SilentlyContinue |
    Format-Table -AutoSize Name, Id, Path
if (-not (Get-Process -Name vdagent -ErrorAction SilentlyContinue)) {
    Write-Host "vdagent.exe is not running in this session." -ForegroundColor Yellow
    Write-Host "Install SPICE Guest Tools (spice-guest-tools-*.exe from spice-space.org), reboot, log in again."
    Write-Host "Do NOT start vdservice.exe by hand - use the installer so the service is registered."
}

Write-Host ""
Write-Host "vdagent log (last errors):"
$log = Join-Path $env:WINDIR "Temp\vdagent.txt"
if (Test-Path $log) {
    Get-Content $log -Tail 15
} else {
    Write-Host "(no $log yet)"
}

Write-Host ""
Write-Host "=== VioGpu Resolution Service (prevents black screen after reboot) ===" -ForegroundColor Cyan
$vgpusrv = Join-Path $VirtioDrive "viogpudo\w11\ARM64\vgpusrv.exe"
$viogpuap = Join-Path $VirtioDrive "viogpudo\w11\ARM64\viogpuap.exe"
if ((Test-Path $vgpusrv) -and (Test-Path $viogpuap)) {
    Copy-Item $vgpusrv, $viogpuap -Destination "$env:WINDIR\System32" -Force
    Push-Location "$env:WINDIR\System32"
    & .\vgpusrv.exe -i
    Pop-Location
    Write-Host "Installed vgpusrv. After reboot, virtio-gpu display should stay on (GPU=virtio on host)."
} else {
    Write-Host "WARNING: viogpudo ARM64 binaries not found on $VirtioDrive" -ForegroundColor Yellow
    Write-Host "Without vgpusrv, rebooting with GPU=virtio causes 'Display output not active'."
    Write-Host "Recover on the Mac with: RECOVER=1 ./win11_osx.sh"
}

Write-Host ""
Write-Host "After driver install: REBOOT, log in, confirm vdagent.exe in Task Manager, then copy/paste in the QEMU window."
Write-Host "If the QEMU window is black after reboot, on the Mac run: RECOVER=1 ./win11_osx.sh"
