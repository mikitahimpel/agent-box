# Checks and installs the Windows side of the agent PC setup.
#
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1            check only
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1 -Install   install or fix
#
# Run from an administrator PowerShell. Written for Windows PowerShell 5.1.

param(
    [switch]$Install,
    [string]$Distro = "Ubuntu",
    [int]$WslMemoryGB = 0
)

$ErrorActionPreference = "Stop"

$DataDir      = Join-Path $env:ProgramData "agent-box"
$WatchdogPath = Join-Path $DataDir "watchdog.ps1"
$WatchdogTask = "agent-box net watchdog"
$KeepaliveTask = "agent-box WSL keepalive"
$WslConfig    = Join-Path $env:USERPROFILE ".wslconfig"

$script:Counts = @{ ok = 0; installed = 0; missing = 0; failed = 0 }
$script:Notes = New-Object System.Collections.Generic.List[string]

function Write-Ok($m)      { $script:Counts.ok++;        Write-Host "  [ok]      $m" -ForegroundColor Green }
function Write-Missing($m) { $script:Counts.missing++;   Write-Host "  [missing] $m" -ForegroundColor Yellow }
function Write-Fixed($m)   { $script:Counts.installed++; Write-Host "  [fixed]   $m" -ForegroundColor Green }
function Write-Failed($m)  { $script:Counts.failed++;    Write-Host "  [failed]  $m" -ForegroundColor Red }
function Write-Info($m)    { Write-Host "            $m" -ForegroundColor DarkGray }
function Write-Section($m) { Write-Host ""; Write-Host $m }

# Step: the check scriptblock returns $true when the component is in the wanted state.
function Test-Check([scriptblock]$Check) {
    try { [bool](& $Check) } catch { $false }
}

function Step([string]$Name, [scriptblock]$Check, [scriptblock]$Fix) {
    if (Test-Check $Check) { Write-Ok $Name; return }
    if (-not $Install) { Write-Missing $Name; return }
    Write-Info "installing: $Name"
    try {
        & $Fix
        if (Test-Check $Check) { Write-Fixed $Name } else { Write-Failed $Name }
    } catch {
        Write-Info $_.Exception.Message
        Write-Failed $Name
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# AC value of a powercfg setting; the AC and DC indexes are the last two hex values printed.
function Get-AcPowerValue([string]$Sub, [string]$Setting) {
    $hex = [regex]::Matches((powercfg /q SCHEME_CURRENT $Sub $Setting | Out-String), '0x[0-9a-fA-F]{8}')
    if ($hex.Count -lt 2) { return $null }
    [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
}

function Get-WifiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -match '802\.11' } |
        Select-Object -First 1
}

# Goes through cmd so stderr from wsl.exe cannot trip $ErrorActionPreference.
function Test-Distro {
    cmd /c "wsl.exe -d $Distro -- true >nul 2>&1"
    $LASTEXITCODE -eq 0
}

if (-not (Test-Admin)) {
    Write-Host "Run this from an administrator PowerShell." -ForegroundColor Red
    exit 2
}

$mode = "check"
if ($Install) { $mode = "install" }
Write-Host "agent-box - windows - mode: $mode"

Write-Section "Hardware and WSL"
Step "CPU virtualization (SVM) enabled" {
    (Get-CimInstance Win32_ComputerSystem).HypervisorPresent -or
        (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
} {
    Write-Info "enable BIOS -> Tweaker -> Advanced CPU Settings -> SVM Mode, then rerun"
}

Step "WSL distro '$Distro' installed" { Test-Distro } {
    & wsl.exe --install -d $Distro
    $script:Notes.Add("Reboot, open Ubuntu once to create your Linux user, then rerun this script.")
}

Step "WSL memory cap in .wslconfig" {
    (Test-Path $WslConfig) -and (Select-String -Path $WslConfig -Pattern '^\s*memory\s*=' -Quiet)
} {
    if ((Test-Path $WslConfig) -and (Get-Content $WslConfig -Raw).Trim()) {
        Write-Info "$WslConfig already exists; add 'memory=<N>GB' under [wsl2] yourself"
        return
    }
    $gb = $WslMemoryGB
    if ($gb -le 0) {
        $total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        $gb = [math]::Max(4, [math]::Floor($total / 1GB / 2))
    }
    Set-Content -Path $WslConfig -Value "[wsl2]`r`nmemory=${gb}GB" -Encoding ASCII
    $script:Notes.Add("WSL memory cap set to ${gb}GB; it applies after 'wsl --shutdown'.")
}

Write-Section "Power"
Step "Sleep on AC power: never" {
    (Get-AcPowerValue SUB_SLEEP STANDBYIDLE) -eq 0 -and (Get-AcPowerValue SUB_SLEEP HIBERNATEIDLE) -eq 0
} {
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
}

$wifi = Get-WifiAdapter
if ($wifi) {
    Step "Wi-Fi adapter '$($wifi.Name)' never powered off to save power" {
        (Get-NetAdapterPowerManagement -Name $wifi.Name).AllowComputerToTurnOffDevice -ne "Enabled"
    } {
        Set-NetAdapterPowerManagement -Name $wifi.Name -AllowComputerToTurnOffDevice Disabled -NoRestart
    }
} else {
    Write-Info "no Wi-Fi adapter found; skipping Wi-Fi checks"
}

Write-Section "Scheduled tasks"
$watchdogBody = @"
# Managed by agent-box. Resets Wi-Fi when the internet is unreachable.
if (-not (Test-Connection 1.1.1.1 -Count 2 -Quiet)) {
    Get-NetAdapter -Physical | Where-Object { `$_.PhysicalMediaType -match '802\.11' } |
        Restart-NetAdapter -Confirm:`$false
}
"@

Step "Network watchdog task (boot + every 3 min)" {
    (Test-Path $WatchdogPath) -and
        ((Get-Content $WatchdogPath -Raw).Trim() -eq $watchdogBody.Trim()) -and
        (Get-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue)
} {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Set-Content -Path $WatchdogPath -Value $watchdogBody -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$WatchdogPath`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 3))
    )
    Register-ScheduledTask -TaskName $WatchdogTask -Action $action -Trigger $triggers `
        -User "SYSTEM" -RunLevel Highest -Force | Out-Null
}

Step "WSL keepalive task (boot + every 5 min)" {
    $null -ne (Get-ScheduledTask -TaskName $KeepaliveTask -ErrorAction SilentlyContinue)
} {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Info "The task runs as $user before anyone logs in, so Windows needs your password."
    Write-Info "With a Microsoft account, use its password, not your PIN."
    $secure = Read-Host "Windows password for $user" -AsSecureString
    $plain = (New-Object System.Net.NetworkCredential("", $secure)).Password
    $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Distro -- sleep infinity"
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $KeepaliveTask -Action $action -Trigger $triggers `
        -Settings $settings -User $user -Password $plain -Force | Out-Null
    Start-ScheduledTask -TaskName $KeepaliveTask
    $script:Notes.Add("If you change your Windows password, rerun with -Install after deleting the '$KeepaliveTask' task.")
}

Write-Host ""
Write-Host ("{0} ok - {1} installed - {2} missing - {3} failed" -f `
    $Counts.ok, $Counts.installed, $Counts.missing, $Counts.failed)
if ($Notes.Count -gt 0) {
    Write-Host ""
    Write-Host "Manual steps:"
    $Notes | ForEach-Object { Write-Host "  - $_" }
}
if (-not $Install -and $Counts.missing -gt 0) {
    Write-Host ""
    Write-Host "Rerun with -Install to fix missing items." -ForegroundColor Yellow
}
if ($Counts.missing -gt 0 -or $Counts.failed -gt 0) { exit 1 }
