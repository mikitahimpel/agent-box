# Checks and installs the Windows side of agent-box (Windows host running WSL).
#
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1            check only
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1 -Install   install or fix
#
# Options: -Distro Ubuntu  -WslMemoryGB <n>  -BackupDir <path>  -BackupKeep <n>
#
# Run from an administrator PowerShell. Written for Windows PowerShell 5.1.

param(
    [switch]$Install,
    [string]$Distro = "Ubuntu",
    [int]$WslMemoryGB = 0,
    [string]$BackupDir = (Join-Path $env:USERPROFILE "wsl-backups"),
    [int]$BackupKeep = 3
)

$ErrorActionPreference = "Stop"

$DataDir       = Join-Path $env:ProgramData "agent-box"
$WatchdogPath  = Join-Path $DataDir "watchdog.ps1"
$ShutdownPath  = Join-Path $DataDir "shutdown.ps1"
$BackupPath    = Join-Path $DataDir "backup.ps1"
$WatchdogTask  = "agent-box net watchdog"
$KeepaliveTask = "agent-box WSL keepalive"
$ShutdownTask  = "agent-box remote shutdown"
$BackupTask    = "agent-box WSL snapshot"
$WslConfig     = Join-Path $env:USERPROFILE ".wslconfig"

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

# Tasks that touch WSL must run as you, because WSL distros belong to a user account.
# They run before anyone logs in, so Windows needs your password once per -Install run.
$TaskUser = "$env:USERDOMAIN\$env:USERNAME"
function Get-TaskPassword {
    if (-not $script:TaskPassword) {
        Write-Info "Tasks run as $TaskUser before anyone logs in, so Windows needs your password."
        Write-Info "With a Microsoft account, use its password, not your PIN."
        $secure = Read-Host "Windows password for $TaskUser" -AsSecureString
        $script:TaskPassword = (New-Object System.Net.NetworkCredential("", $secure)).Password
        $script:Notes.Add("If you change your Windows password, delete the 'agent-box' tasks and rerun with -Install.")
    }
    $script:TaskPassword
}

function Test-ManagedScript([string]$Path, [string]$Body) {
    (Test-Path $Path) -and ((Get-Content $Path -Raw).Trim() -eq $Body.Trim())
}
function Write-ManagedScript([string]$Path, [string]$Body) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -Path $Path -Value $Body -Encoding UTF8
}
function Test-Task([string]$Name) {
    $null -ne (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue)
}
function New-ScriptAction([string]$Path) {
    New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Path`""
}
function New-BootAndRepeatTriggers([int]$Minutes) {
    @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes))
    )
}
function Register-UserTask([string]$Name, $Action, $Triggers, $Settings) {
    Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Triggers -Settings $Settings `
        -User $TaskUser -Password (Get-TaskPassword) -Force | Out-Null
}

$watchdogBody = @"
# Managed by agent-box. Resets Wi-Fi when the internet is unreachable.
if (-not (Test-Connection 1.1.1.1 -Count 2 -Quiet)) {
    Get-NetAdapter -Physical | Where-Object { `$_.PhysicalMediaType -match '802\.11' } |
        Restart-NetAdapter -Confirm:`$false
}
"@

Step "Network watchdog task (boot + every 3 min)" {
    (Test-ManagedScript $WatchdogPath $watchdogBody) -and (Test-Task $WatchdogTask)
} {
    Write-ManagedScript $WatchdogPath $watchdogBody
    Register-ScheduledTask -TaskName $WatchdogTask -Action (New-ScriptAction $WatchdogPath) `
        -Trigger (New-BootAndRepeatTriggers 3) -User "SYSTEM" -RunLevel Highest -Force | Out-Null
}

Step "WSL keepalive task (boot + every 5 min)" { Test-Task $KeepaliveTask } {
    $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $Distro -- sleep infinity"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-UserTask $KeepaliveTask $action (New-BootAndRepeatTriggers 5) $settings
    Start-ScheduledTask -TaskName $KeepaliveTask
}

# `agent-box off` on any machine creates ~/.agent-box/shutdown inside WSL; this task
# asks WSL whether a fresh request exists and shuts Windows down if so.
$shutdownBody = @"
# Managed by agent-box. Shuts Windows down when 'agent-box off' was run.
& wsl.exe -d $Distro -- ~/.local/bin/agent-box _shutdown-pending
if (`$LASTEXITCODE -eq 0) {
    shutdown.exe /s /t 30 /c "agent-box: shutdown requested"
}
"@

Step "Remote shutdown task (every 1 min)" {
    (Test-ManagedScript $ShutdownPath $shutdownBody) -and (Test-Task $ShutdownTask)
} {
    Write-ManagedScript $ShutdownPath $shutdownBody
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-UserTask $ShutdownTask (New-ScriptAction $ShutdownPath) (New-BootAndRepeatTriggers 1) $settings
}

$backupBody = @"
# Managed by agent-box. Exports the WSL distro and keeps the newest $BackupKeep copies.
`$dir = '$BackupDir'
New-Item -ItemType Directory -Force -Path `$dir | Out-Null
`$file = Join-Path `$dir ('$Distro-' + (Get-Date -Format 'yyyy-MM-dd') + '.tar')
& wsl.exe --export $Distro `$file
if (`$LASTEXITCODE -ne 0) {
    Remove-Item `$file -Force -ErrorAction SilentlyContinue
    exit 1
}
Get-ChildItem `$dir -Filter '$Distro-*.tar' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $BackupKeep | Remove-Item -Force
"@

Step "Weekly WSL snapshot to $BackupDir (keeps $BackupKeep)" {
    (Test-ManagedScript $BackupPath $backupBody) -and (Test-Task $BackupTask)
} {
    Write-ManagedScript $BackupPath $backupBody
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
    # StartWhenAvailable runs a missed snapshot at the next boot, since the PC is often off.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-UserTask $BackupTask (New-ScriptAction $BackupPath) $trigger $settings
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
