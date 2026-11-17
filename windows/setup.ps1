# Checks and installs the Windows side of agent-box (Windows host running WSL).
#
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1            check only
#   powershell -ExecutionPolicy Bypass -File windows\setup.ps1 -Install   install or fix
#
# Options: -Distro Ubuntu  -WslMemoryGB <n>  -WslSwapGB <n>  -BackupDir <path>  -BackupKeep <n>
#          -AgentHost <name>  -GitHubUser <login>  -LanSubnet <a.b.c.d/n>
#          -SleepWhenIdle on|off  -IdleMinutes <n>   (these two are saved for later runs)
#
# Run from an administrator PowerShell. Written for Windows PowerShell 5.1.

param(
    [switch]$Install,
    [string]$Distro = "Ubuntu",
    [int]$WslMemoryGB = 0,
    [int]$WslSwapGB = 0,
    [string]$BackupDir = (Join-Path $env:USERPROFILE "wsl-backups"),
    [int]$BackupKeep = 3,
    [string]$AgentHost = "",
    [string]$GitHubUser = "",
    [string]$LanSubnet = "",
    [ValidateSet("", "on", "off")][string]$SleepWhenIdle = "",
    [int]$IdleMinutes = 0
)

$ErrorActionPreference = "Stop"

$DataDir       = Join-Path $env:ProgramData "agent-box"
$WatchdogPath  = Join-Path $DataDir "watchdog.ps1"
$ShutdownPath  = Join-Path $DataDir "shutdown.ps1"
$BackupPath    = Join-Path $DataDir "backup.ps1"
$KeepalivePath = Join-Path $DataDir "keepalive.ps1"
$AgentsOffPath = Join-Path $DataDir "agents-off.ps1"
$AgentsOnPath  = Join-Path $DataDir "agents-on.ps1"
$WslWatchdogPath = Join-Path $DataDir "wsl-watchdog.ps1"
$PowerLogPath  = Join-Path $DataDir "power-log.ps1"
$IdleSleepPath = Join-Path $DataDir "idle-sleep.ps1"
$ActionLog     = Join-Path $DataDir "agent-box.log"
$PowerEventsLog = Join-Path $DataDir "power-events.log"
$SettingsFile  = Join-Path $DataDir "config"
$PausedFlag    = Join-Path $env:LOCALAPPDATA "agent-box\paused"
$WatchdogTask  = "agent-box net watchdog"
$KeepaliveTask = "agent-box WSL keepalive"
$ShutdownTask  = "agent-box remote shutdown"
$BackupTask    = "agent-box WSL snapshot"
$WslWatchdogTask = "agent-box WSL watchdog"
$PowerLogTask  = "agent-box power events log"
$IdleSleepTask = "agent-box idle sleep"
$SshdConfig    = Join-Path $env:ProgramData "ssh\sshd_config"
$AdminKeys     = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
$TailscaleExe  = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
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

# Files this script owns are rewritten whenever their content differs.
function Test-ManagedScript([string]$Path, [string]$Body) {
    (Test-Path $Path) -and ((Get-Content $Path -Raw).Trim() -eq $Body.Trim())
}
function Write-ManagedScript([string]$Path, [string]$Body) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -Path $Path -Value $Body -Encoding UTF8
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

# Missing when the driver has no power-off option, which counts as never powered off.
function Get-WifiPowerSetting($Adapter) {
    Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceName -like "$($Adapter.PnPDeviceID)*" } |
        Select-Object -First 1
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
function Get-WslText([string]$Command) {
    ((cmd /c "wsl.exe -d $Distro -- $Command 2>nul") -join "`n").Trim()
}

# Runs a native command with its stderr dropped; in Windows PowerShell 5.1 redirected
# stderr would otherwise become a terminating error under $ErrorActionPreference = Stop.
function Invoke-Quiet([scriptblock]$Block) {
    $ErrorActionPreference = "Continue"
    & $Block 2>$null
}

# -SleepWhenIdle and -IdleMinutes are kept in $SettingsFile, so a later run of the
# one-line installer (which passes no options) doesn't switch them back.
function Get-SavedSetting([string]$Name) {
    if (-not (Test-Path $SettingsFile)) { return "" }
    $line = Get-Content $SettingsFile | Where-Object { $_ -like "$Name=*" } | Select-Object -Last 1
    if ($line) { $line.Substring($Name.Length + 1).Trim() } else { "" }
}
if (-not $SleepWhenIdle) { $SleepWhenIdle = Get-SavedSetting "SleepWhenIdle" }
if ($SleepWhenIdle -ne "on") { $SleepWhenIdle = "off" }
if ($IdleMinutes -le 0) { $IdleMinutes = [int](Get-SavedSetting "IdleMinutes") }
if ($IdleMinutes -le 0) { $IdleMinutes = 30 }

# IPv4 network of the interface holding the default route, e.g. 192.168.1.0/24.
function Get-LocalSubnet {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { return $null }
    $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
    if (-not $addr) { return $null }
    $bytes = ([Net.IPAddress]$addr.IPAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    $ip = [int64][BitConverter]::ToUInt32($bytes, 0)
    $mask = [int64]0
    if ($addr.PrefixLength -gt 0) { $mask = [int64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $addr.PrefixLength)) }
    $net = [BitConverter]::GetBytes([uint32]($ip -band $mask))
    [Array]::Reverse($net)
    "{0}/{1}" -f ([Net.IPAddress]::new($net).ToString()), $addr.PrefixLength
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

# Agents are switched off for games ('Agents off'), so WSL may use all but 4GB.
# A .wslconfig this script did not write is left alone.
$wslMemory = $WslMemoryGB
if ($wslMemory -le 0) {
    $total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $wslMemory = [math]::Max(4, [math]::Round($total / 1GB) - 4)
}
# Swap lets a burst of builds slow down instead of crashing the VM (earlyoom in WSL
# still kills the biggest job first).
$wslSwap = $WslSwapGB
if ($wslSwap -le 0) { $wslSwap = [math]::Min(16, [math]::Max(8, [math]::Round($wslMemory / 2))) }
# vmIdleTimeout=-1: WSL otherwise shuts down a few minutes after its last window
# closes, taking agents and the Tailscale inside it along.
$wslConfigBody = "# Managed by agent-box.`r`n[wsl2]`r`nmemory=${wslMemory}GB`r`nswap=${wslSwap}GB`r`nvmIdleTimeout=-1"
function Test-ManagedWslConfig {
    if (-not (Test-Path $WslConfig)) { return $true }
    $text = (Get-Content $WslConfig -Raw).Trim()
    # Earlier versions wrote the same file without the marker.
    (-not $text) -or $text.StartsWith("# Managed by agent-box.") -or ($text -match '^\[wsl2\]\s+memory=\d+GB$')
}
Step "WSL memory ${wslMemory}GB and swap ${wslSwap}GB in .wslconfig" {
    if (Test-ManagedWslConfig) { Test-ManagedScript $WslConfig $wslConfigBody }
    else {
        (Select-String -Path $WslConfig -Pattern '^\s*memory\s*=' -Quiet) -and
            (Select-String -Path $WslConfig -Pattern '^\s*swap\s*=' -Quiet)
    }
} {
    if (-not (Test-ManagedWslConfig)) {
        Write-Info "$WslConfig was not written by agent-box; add 'memory=<N>GB' and 'swap=<N>GB' under [wsl2] yourself"
        return
    }
    Set-Content -Path $WslConfig -Value $wslConfigBody -Encoding ASCII
    $script:Notes.Add("WSL memory (${wslMemory}GB) and swap (${wslSwap}GB) apply the next time WSL starts (restart the PC).")
}

# Every write inside WSL lands in the distro's ext4.vhdx through these processes.
# Defender's real-time scan of them adds latency to each write and keeps a core
# busy during builds and CI, so the disk and the processes are excluded.
$WslProcesses = @("vmmem", "vmmemWSL", "wsl.exe", "wslhost.exe", "wslrelay.exe", "wslservice.exe")
function Get-DistroFolder {
    $key = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { $_.DistributionName -eq $Distro } | Select-Object -First 1
    if ($key) { $key.BasePath -replace '^\\\\\?\\', '' }
}
$defenderOn = $false
try { $defenderOn = (Get-MpComputerStatus -ErrorAction Stop).AMServiceEnabled } catch { }
$distroFolder = Get-DistroFolder
if ($defenderOn -and $distroFolder) {
    Step "Defender skips WSL's disk and processes" {
        $p = Get-MpPreference
        ($p.ExclusionPath -contains $distroFolder) -and
            (@($WslProcesses | Where-Object { $p.ExclusionProcess -notcontains $_ }).Count -eq 0)
    } {
        Add-MpPreference -ExclusionPath $distroFolder -ExclusionProcess $WslProcesses
    }
} elseif (-not $defenderOn) {
    Write-Info "Microsoft Defender isn't the active antivirus; skipping WSL exclusions"
}

Write-Section "Power"
# Fast Startup resumes a hibernated kernel, which skips startup task triggers and
# keeps the last boot time, so 'Agents off' would outlast a power cycle.
$powerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
Step "Fast Startup off" {
    (Get-ItemProperty $powerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled -eq 0
} {
    Set-ItemProperty $powerKey -Name HiberbootEnabled -Value 0 -Type DWord
}

Step "Sleep on AC power: never" {
    (Get-AcPowerValue SUB_SLEEP STANDBYIDLE) -eq 0 -and (Get-AcPowerValue SUB_SLEEP HIBERNATEIDLE) -eq 0
} {
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
}

# With -SleepWhenIdle on, the idle-sleep task decides when to sleep. SetSuspendState
# hibernates instead of sleeping while hibernation is on, and a hibernated PC can't
# be woken over the network.
if ($SleepWhenIdle -eq "on") {
    Step "Hibernation off (sleep when idle uses S3 sleep)" {
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 0
    } {
        powercfg /hibernate off
    }
}

$wifi = Get-WifiAdapter
if ($wifi) {
    # "Allow the computer to turn off this device" in Device Manager. Set-NetAdapterPowerManagement
    # can't change it, so this goes through the same WMI setting the checkbox uses.
    # Windows only lets a device wake the PC while that box is ticked, so sleep when idle
    # needs it on; otherwise it stays off, which keeps Wi-Fi from dropping out.
    if ($SleepWhenIdle -eq "on") {
        Step "Wi-Fi adapter '$($wifi.Name)' may power down while the PC sleeps (to wake it)" {
            $p = Get-WifiPowerSetting $wifi
            (-not $p) -or $p.Enable
        } {
            Set-CimInstance -InputObject (Get-WifiPowerSetting $wifi) -Property @{ Enable = $true }
        }
    } else {
        Step "Wi-Fi adapter '$($wifi.Name)' never powered off to save power" {
            $p = Get-WifiPowerSetting $wifi
            (-not $p) -or (-not $p.Enable)
        } {
            Set-CimInstance -InputObject (Get-WifiPowerSetting $wifi) -Property @{ Enable = $false }
        }
    }

    # Wake-on-LAN over Wi-Fi: the driver's own settings, then Windows' permission to wake.
    # Drivers name them differently and many have none; "Wake on Pattern Match" is left
    # alone because it wakes the PC on ordinary traffic.
    $onValue = '^(Enabled|On)$'
    $wakeProps = @(Get-NetAdapterAdvancedProperty -Name $wifi.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Magic Packet|WoWLAN|Wake on WLAN' -and ($_.ValidDisplayValues -match $onValue) })
    $wakePm = Get-NetAdapterPowerManagement -Name $wifi.Name -ErrorAction SilentlyContinue
    $magicPm = $wakePm -and ("$($wakePm.WakeOnMagicPacket)" -notin @("", "Unsupported"))
    $found = @($wakeProps | ForEach-Object { "$($_.DisplayName) = $($_.DisplayValue)" })
    if ($magicPm) { $found += "power management Wake on Magic Packet = $($wakePm.WakeOnMagicPacket)" }
    if ($found.Count -gt 0) {
        Write-Info ("Wi-Fi wake settings found: " + ($found -join "; "))
        Step "Wi-Fi Wake on Magic Packet / WoWLAN on" {
            $names = @($wakeProps | ForEach-Object { $_.DisplayName })
            $off = @(Get-NetAdapterAdvancedProperty -Name $wifi.Name |
                Where-Object { $names -contains $_.DisplayName -and $_.DisplayValue -notmatch $onValue })
            ($off.Count -eq 0) -and
                ((-not $magicPm) -or "$((Get-NetAdapterPowerManagement -Name $wifi.Name).WakeOnMagicPacket)" -eq "Enabled")
        } {
            foreach ($p in $wakeProps) {
                $on = $p.ValidDisplayValues | Where-Object { $_ -match $onValue } | Select-Object -First 1
                Set-NetAdapterAdvancedProperty -Name $wifi.Name -DisplayName $p.DisplayName -DisplayValue $on
            }
            if ($magicPm) { Set-NetAdapterPowerManagement -Name $wifi.Name -WakeOnMagicPacket Enabled }
        }
    } else {
        Write-Info "the Wi-Fi driver has no Wake on Magic Packet or WoWLAN setting"
    }

    # "Allow this device to wake the computer" in Device Manager.
    $wifiDevice = (Get-PnpDevice -InstanceId $wifi.PnPDeviceID -ErrorAction SilentlyContinue).FriendlyName
    $canWake = $wifiDevice -and (@(powercfg /devicequery wake_programmable | ForEach-Object { $_.Trim() }) -contains $wifiDevice)
    if ($canWake) {
        Step "Wi-Fi adapter may wake the computer" {
            @(powercfg /devicequery wake_armed | ForEach-Object { $_.Trim() }) -contains $wifiDevice
        } {
            powercfg /deviceenablewake "$wifiDevice"
        }
        Write-Info "Wake-on-LAN from the router: ether-wake -i br0 $($wifi.MacAddress -replace '-', ':')"
    } else {
        Write-Info "Windows doesn't list '$wifiDevice' as able to wake the computer"
    }
} else {
    Write-Info "no Wi-Fi adapter found; skipping Wi-Fi checks"
}

Write-Section "Windows remote access"
# Tailscale and SSH on Windows itself, so the PC can be reached (to restart WSL, read
# logs) when WSL, and the Tailscale inside it, is down. Its Tailscale name is the
# WSL host's name plus -win.
$wslUp = Test-Distro
if (-not $AgentHost -and $wslUp) {
    $m = [regex]::Match((Get-WslText "cat ~/.config/agent-box/config"), '(?m)^AGENT_HOST=(\S+)')
    if ($m.Success) { $AgentHost = $m.Groups[1].Value }
}
if (-not $AgentHost) { $AgentHost = $env:COMPUTERNAME.ToLower() }
$winHost = "$AgentHost-win"

function Get-WinTailscale([string]$Kind) {  # status | prefs
    if (-not (Test-Path $TailscaleExe)) { return $null }
    $cmdArgs = @("status", "--json")
    if ($Kind -eq "prefs") { $cmdArgs = @("debug", "prefs") }
    $text = Invoke-Quiet { & $TailscaleExe @cmdArgs } | Out-String
    if ($text.Trim()) { $text | ConvertFrom-Json }
}

Step "Tailscale for Windows installed" { Test-Path $TailscaleExe } {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Info "winget not found; install Tailscale from https://tailscale.com/download/windows, then rerun"
        return
    }
    & winget install --id Tailscale.Tailscale --exact --silent --accept-package-agreements --accept-source-agreements
}

if (Test-Path $TailscaleExe) {
    # Unattended mode keeps Tailscale connected with nobody logged in to Windows.
    Step "Windows on Tailscale as '$winHost', before anyone logs in (unattended)" {
        $prefs = Get-WinTailscale prefs
        ((Get-WinTailscale status).BackendState -eq "Running") -and ($prefs.Hostname -eq $winHost) -and $prefs.ForceDaemon
    } {
        if ((Get-WinTailscale status).BackendState -eq "Running") {
            & $TailscaleExe set --unattended --hostname=$winHost
        } else {
            Write-Info "log in with the link Tailscale prints, with the same account as your other machines"
            & $TailscaleExe up --unattended --hostname=$winHost
        }
    }
    $script:Notes.Add("Tailscale admin console: disable key expiry for '$winHost'.")
}

Step "OpenSSH Server installed" {
    $null -ne (Get-Service sshd -ErrorAction SilentlyContinue)
} {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}

# Only Tailscale (IPv4 and IPv6) and the local network may reach port 22. The local
# network is detected each run; on another network, rerun to follow it.
$lan = $LanSubnet
if (-not $lan) { $lan = Get-LocalSubnet }
if (-not $lan) { $lan = "192.168.50.0/24" }
$sshFrom = @("100.64.0.0/10", "fd7a:115c:a1e0::/48", $lan)
$sshRuleName = "agent-box-ssh"
$sshRuleDescription = "Managed by agent-box. SSH from: $($sshFrom -join ', ')"
Step "Windows SSH reachable only from Tailscale and $lan" {
    $rule = Get-NetFirewallRule -Name $sshRuleName -ErrorAction SilentlyContinue
    $open = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    $rule -and ("$($rule.Enabled)" -eq "True") -and ($rule.Description -eq $sshRuleDescription) -and
        ((-not $open) -or ("$($open.Enabled)" -eq "False"))
} {
    Remove-NetFirewallRule -Name $sshRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $sshRuleName -DisplayName "agent-box SSH (Tailscale and local network)" `
        -Description $sshRuleDescription -Direction Inbound -Protocol TCP -LocalPort 22 `
        -RemoteAddress $sshFrom -Action Allow -Profile Any | Out-Null
    # The rule OpenSSH adds when installed allows port 22 from anywhere.
    if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue) {
        Disable-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
    }
}

if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Step "OpenSSH Server starts at boot" {
        $svc = Get-Service sshd
        ("$($svc.StartType)" -eq "Automatic") -and ("$($svc.Status)" -eq "Running")
    } {
        Set-Service sshd -StartupType Automatic
        Start-Service sshd
    }

    # sshd uses the first value it reads, so the managed line goes first. The file
    # stays ASCII: sshd doesn't accept a byte order mark.
    $sshdMark = "# Managed by agent-box: keys only."
    function Get-SshdOption([string]$Name) {
        if (-not (Test-Path $SshdConfig)) { return $null }
        $m = Select-String -Path $SshdConfig -Pattern "^\s*$Name\s+(\S+)" | Select-Object -First 1
        if ($m) { $m.Matches[0].Groups[1].Value }
    }
    Step "Windows SSH accepts keys only (PasswordAuthentication no)" {
        (Get-SshdOption "PasswordAuthentication") -eq "no"
    } {
        $lines = @(Get-Content $SshdConfig | Where-Object { $_ -notmatch '^\s*PasswordAuthentication\s' -and $_ -ne $sshdMark })
        Copy-Item $SshdConfig "$SshdConfig.bak" -Force
        Set-Content -Path $SshdConfig -Value (@($sshdMark, "PasswordAuthentication no", "") + $lines) -Encoding ASCII
        & (Join-Path $env:WINDIR "System32\OpenSSH\sshd.exe") -t
        if ($LASTEXITCODE -ne 0) {
            Copy-Item "$SshdConfig.bak" $SshdConfig -Force
            throw "sshd -t rejected the new config; the old one is back"
        }
        Restart-Service sshd
    }

    $psExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    Step "Windows SSH opens PowerShell" {
        (Get-ItemProperty "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell -eq $psExe
    } {
        if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" | Out-Null }
        New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $psExe -PropertyType String -Force | Out-Null
    }

    # The same keys that push to GitHub: every agent-box machine uploads its own key
    # there (github.com/<you>.keys). Windows' sshd reads the keys of administrators,
    # which you are, from administrators_authorized_keys, not from ~\.ssh.
    if (-not $GitHubUser -and $wslUp) { $GitHubUser = Get-WslText "gh api user --jq .login" }
    $sshKeys = @()
    if ($GitHubUser) {
        try {
            $sshKeys = @((Invoke-WebRequest "https://github.com/$GitHubUser.keys" -UseBasicParsing).Content -split "`n" |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } catch {
            Write-Info "couldn't read https://github.com/$GitHubUser.keys: $($_.Exception.Message)"
        }
    }
    if ($sshKeys.Count -gt 0) {
        $keysMark = "# Managed by agent-box."
        $keysBody = (@("$keysMark SSH keys of github.com/$GitHubUser, one per machine.") + $sshKeys) -join "`r`n"
        Step "Windows SSH accepts your machines' keys (github.com/$GitHubUser.keys)" {
            if (-not (Test-Path $AdminKeys)) { return $false }
            $text = "$(Get-Content $AdminKeys -Raw)"
            if ($text.StartsWith($keysMark)) { $keysOk = $text.Trim() -eq $keysBody.Trim() }
            else { $keysOk = @($sshKeys | Where-Object { -not $text.Contains($_) }).Count -eq 0 }
            $keysOk -and (Get-Acl $AdminKeys).AreAccessRulesProtected
        } {
            $text = ""
            if (Test-Path $AdminKeys) { $text = "$(Get-Content $AdminKeys -Raw)" }
            if ($text -and -not $text.StartsWith($keysMark)) {
                # Someone else's file: add the missing keys, keep the rest.
                $missingKeys = @($sshKeys | Where-Object { -not $text.Contains($_) })
                if ($missingKeys.Count -gt 0) { Add-Content -Path $AdminKeys -Value (@("") + $missingKeys) -Encoding ASCII }
            } else {
                Set-Content -Path $AdminKeys -Value $keysBody -Encoding ASCII
            }
            # sshd ignores this file unless only Administrators and SYSTEM can change it.
            icacls.exe $AdminKeys /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
        }
        $script:Notes.Add("On the Mac, rerun agent-box: it adds 'Host $winHost' (user $env:USERNAME) to ~/.ssh/config. Then 'ssh $winHost'.")
    } else {
        Write-Info "skipping Windows SSH keys: GitHub user unknown or has no keys; finish the Linux setup"
        Write-Info "(gh logged in inside WSL) and rerun, or pass -GitHubUser <login>"
    }
}

# Clients read this to add '$winHost' with the right Windows user to their SSH config.
if ($wslUp) {
    $winFile = "WINDOWS_HOST=$winHost`nWINDOWS_USER=$env:USERNAME"
    Step "WSL knows its Windows side ($env:USERNAME@$winHost)" {
        (Get-WslText "cat ~/.config/agent-box/windows") -eq $winFile
    } {
        $sh = "mkdir -p ~/.config/agent-box && printf 'WINDOWS_HOST=%s\nWINDOWS_USER=%s\n' '$winHost' '$env:USERNAME' > ~/.config/agent-box/windows"
        & wsl.exe -d $Distro -- sh -c $sh
    }
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
        $script:Notes.Add("If you change your Windows password, delete the 'agent-box' tasks in Task Scheduler, then run the install command again.")
    }
    $script:TaskPassword
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
# Windows checks the password when the task is registered; a wrong one is asked again.
function Register-UserTask([string]$Name, $Action, $Triggers, $Settings, [string]$RunLevel = "Limited") {
    for ($try = 1; ; $try++) {
        try {
            Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Triggers -Settings $Settings `
                -User $TaskUser -Password (Get-TaskPassword) -RunLevel $RunLevel -Force -ErrorAction Stop | Out-Null
            return
        } catch {
            $badPassword = $_.Exception.HResult -eq -2147023570 -or $_.Exception.Message -match 'password'
            if (-not $badPassword -or $try -ge 3) { throw }
            Write-Host "            Windows rejected that password, try again." -ForegroundColor Yellow
            $script:TaskPassword = $null
        }
    }
}

# A task saved with a password that no longer works (password changed, PC renamed)
# never starts and leaves no trace but failed logons. Such tasks are removed here so
# the steps below register them again with the current account and password.
$UserTasks = @($KeepaliveTask, $ShutdownTask, $WslWatchdogTask)
function Get-StuckTasks {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if (((Get-Date) - $boot).TotalMinutes -lt 15) { return @() }
    @($UserTasks | Where-Object {
        $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
        $t -and ($t.State -eq "Disabled" -or ($t.State -ne "Running" -and
            ($t | Get-ScheduledTaskInfo).LastRunTime -lt (Get-Date).AddMinutes(-15)))
    })
}
Step "Tasks that run as $TaskUser start (saved password still works)" { (Get-StuckTasks).Count -eq 0 } {
    foreach ($name in Get-StuckTasks) {
        Write-Info "registering '$name' again: it hasn't started in 15 minutes"
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

$watchdogBody = @"
# Managed by agent-box. Resets Wi-Fi when the internet is unreachable.
if (-not (Test-Connection 1.1.1.1 -Count 2 -Quiet)) {
    Add-Content -Path '$ActionLog' -Value ((Get-Date -Format 's') + '  net watchdog: internet unreachable, resetting Wi-Fi')
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

# 'Agents off' writes the flag; it counts until the next boot or 'Agents on'.
$pausedCheck = @"
`$flag = Get-Item '$PausedFlag' -ErrorAction SilentlyContinue
if (`$flag -and `$flag.LastWriteTime -gt (Get-CimInstance Win32_OperatingSystem).LastBootUpTime) { exit 0 }
"@

$keepaliveBody = @"
# Managed by agent-box. Keeps WSL running unless agents were switched off.
$pausedCheck
& wsl.exe -d $Distro -- sleep infinity
"@

Step "WSL keepalive task (boot + every 5 min)" {
    (Test-ManagedScript $KeepalivePath $keepaliveBody) -and
        ((Get-ScheduledTask -TaskName $KeepaliveTask).Actions[0].Arguments -like "*$KeepalivePath*")
} {
    Write-ManagedScript $KeepalivePath $keepaliveBody
    $action = New-ScriptAction $KeepalivePath
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-UserTask $KeepaliveTask $action (New-BootAndRepeatTriggers 5) $settings
    Start-ScheduledTask -TaskName $KeepaliveTask
}

# `agent-box off` / `agent-box restart` on any machine creates ~/.agent-box/shutdown or
# ~/.agent-box/restart inside WSL; this task asks WSL whether a fresh request exists
# and shuts Windows down or restarts it.
$shutdownBody = @"
# Managed by agent-box. Shuts Windows down or restarts it after 'agent-box off' or 'agent-box restart'.
$pausedCheck
`$action = & wsl.exe -d $Distro -- ~/.local/bin/agent-box _power-pending
if (`$LASTEXITCODE -eq 0) {
    if ("`$action" -match 'restart') {
        shutdown.exe /r /t 30 /c "agent-box: restart requested"
    } else {
        shutdown.exe /s /t 30 /c "agent-box: shutdown requested"
    }
}
"@

Step "Remote shutdown/restart task (every 1 min)" {
    (Test-ManagedScript $ShutdownPath $shutdownBody) -and (Test-Task $ShutdownTask)
} {
    Write-ManagedScript $ShutdownPath $shutdownBody
    if (-not (Test-Task $ShutdownTask)) {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-UserTask $ShutdownTask (New-ScriptAction $ShutdownPath) (New-BootAndRepeatTriggers 1) $settings
    }
}

# Desktop shortcuts to stop WSL with everything in it (agents, CI runners) before
# a game, and to bring it back. Turning the PC on also brings it back.
$agentsOffBody = @"
# Managed by agent-box. Stops WSL and everything in it until 'Agents on' or the next boot.
New-Item -ItemType Directory -Force -Path '$(Split-Path $PausedFlag)' | Out-Null
Set-Content -Path '$PausedFlag' -Value (Get-Date -Format o)
# A task that was already starting WSL can bring it back once.
& wsl.exe --shutdown
Start-Sleep -Seconds 5
& wsl.exe --shutdown
Write-Host "Agents are off until 'Agents on' or the next time the PC starts."
Start-Sleep -Seconds 3
"@

$agentsOnBody = @"
# Managed by agent-box. Starts WSL again after 'Agents off'.
Remove-Item -Path '$PausedFlag' -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName '$KeepaliveTask' -ErrorAction SilentlyContinue
Write-Host "Agents are starting; they show up in the Herdr app within a few minutes."
Start-Sleep -Seconds 3
"@

$Desktop = [Environment]::GetFolderPath("Desktop")
function Test-Shortcut([string]$Name, [string]$Script) {
    $lnk = Join-Path $Desktop "$Name.lnk"
    (Test-Path $lnk) -and ((New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments -like "*$Script*")
}
function New-Shortcut([string]$Name, [string]$Script) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "$Name.lnk"))
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
    $lnk.Save()
}

Step "'Agents off' and 'Agents on' desktop shortcuts" {
    (Test-ManagedScript $AgentsOffPath $agentsOffBody) -and (Test-ManagedScript $AgentsOnPath $agentsOnBody) -and
        (Test-Shortcut "Agents off" $AgentsOffPath) -and (Test-Shortcut "Agents on" $AgentsOnPath)
} {
    Write-ManagedScript $AgentsOffPath $agentsOffBody
    Write-ManagedScript $AgentsOnPath $agentsOnBody
    New-Shortcut "Agents off" $AgentsOffPath
    New-Shortcut "Agents on" $AgentsOnPath
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

# Shared by the task scripts below: wsl.exe calls that can't hang the task (exit
# code -1 on timeout), and the action log with one rotation at 1 MB.
$taskHelpers = @"
function Invoke-Wsl([string]`$Arguments, [int]`$Seconds) {
    `$psi = New-Object Diagnostics.ProcessStartInfo 'wsl.exe', `$Arguments
    `$psi.UseShellExecute = `$false
    `$psi.CreateNoWindow = `$true
    `$psi.RedirectStandardOutput = `$true
    `$p = [Diagnostics.Process]::Start(`$psi)
    `$out = `$p.StandardOutput.ReadToEndAsync()
    if (-not `$p.WaitForExit(`$Seconds * 1000)) {
        try { `$p.Kill() } catch { }
        return @{ Code = -1; Output = '' }
    }
    @{ Code = `$p.ExitCode; Output = "`$(`$out.Result)".Trim() }
}
function Write-Log([string]`$Message) {
    `$log = '$ActionLog'
    if ((Test-Path `$log) -and (Get-Item `$log).Length -gt 1MB) { Move-Item `$log "`$log.old" -Force }
    Add-Content -Path `$log -Value ((Get-Date -Format 's') + '  ' + `$Message)
}
"@

# The keepalive only restarts WSL after it exits. This one catches a WSL that still
# runs but no longer answers (out of memory, stuck), and a tailscaled inside it that
# is down, which takes the host off the tailnet.
$wslWatchdogBody = @"
# Managed by agent-box. Restarts WSL when it stops answering, and tailscaled in it when that is down or offline.
$pausedCheck
# A snapshot export keeps WSL busy for a long time.
if ("`$((Get-ScheduledTask -TaskName '$BackupTask' -ErrorAction SilentlyContinue).State)" -eq 'Running') { exit 0 }
$taskHelpers
function Get-Strikes([string]`$Name) { [int](Get-Content (Join-Path '$DataDir' "`$Name.strikes") -ErrorAction SilentlyContinue) }
function Set-Strikes([string]`$Name, [int]`$Count) {
    `$file = Join-Path '$DataDir' "`$Name.strikes"
    if (`$Count -eq 0) { Remove-Item `$file -Force -ErrorAction SilentlyContinue } else { Set-Content `$file `$Count }
}

if ((Invoke-Wsl '-d $Distro --cd ~ --exec true' 30).Code -eq -1) {
    `$strikes = (Get-Strikes 'wsl') + 1
    Write-Log "WSL watchdog: WSL did not answer within 30 s (`$strikes in a row)"
    if (`$strikes -lt 2) { Set-Strikes 'wsl' `$strikes; exit 0 }
    Set-Strikes 'wsl' 0
    Write-Log 'WSL watchdog: restarting WSL (wsl --shutdown, then the keepalive task)'
    Stop-ScheduledTask -TaskName '$KeepaliveTask' -ErrorAction SilentlyContinue
    if ((Invoke-Wsl '--shutdown' 120).Code -ne 0) {
        Write-Log 'WSL watchdog: wsl --shutdown did not finish; stopping the WSL processes'
        Stop-Process -Name wslservice, wslhost, wsl -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 5
    Start-ScheduledTask -TaskName '$KeepaliveTask'
    exit 0
}
Set-Strikes 'wsl' 0

# 10: tailscaled stopped, 11: it runs but Tailscale isn't up, 12: it is up but lost
# its control connection (seen after a Wi-Fi reset: tailscaled kept waiting on the
# dead connection and the host showed offline). One restart per outage.
`$ts = (Invoke-Wsl '-d $Distro -u root --cd ~ --exec sh -c "systemctl is-enabled --quiet tailscaled || exit 0; systemctl is-active --quiet tailscaled || exit 10; tailscale status >/dev/null 2>&1 || exit 11; command -v jq >/dev/null || exit 0; tailscale status --json 2>/dev/null | jq -e .Self.Online >/dev/null || exit 12"' 30).Code
if (`$ts -eq 10 -or `$ts -eq 11 -or `$ts -eq 12) {
    `$strikes = (Get-Strikes 'tailscale') + 1
    Set-Strikes 'tailscale' `$strikes
    if (`$strikes -eq 2) {
        Write-Log "WSL watchdog: Tailscale in WSL down twice in a row (`$ts); restarting tailscaled"
        Invoke-Wsl '-d $Distro -u root --cd ~ --exec systemctl restart tailscaled' 60 | Out-Null
    } elseif (`$strikes -eq 3) {
        Write-Log 'WSL watchdog: Tailscale in WSL still down after a restart; it may need sudo tailscale up'
    }
} elseif (`$ts -eq 0) {
    Set-Strikes 'tailscale' 0
}
"@

Step "WSL watchdog task (restarts a hung WSL, every 3 min)" {
    (Test-ManagedScript $WslWatchdogPath $wslWatchdogBody) -and (Test-Task $WslWatchdogTask)
} {
    Write-ManagedScript $WslWatchdogPath $wslWatchdogBody
    if (-not (Test-Task $WslWatchdogTask)) {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        # Highest, so it can stop the WSL service when wsl --shutdown hangs too.
        Register-UserTask $WslWatchdogTask (New-ScriptAction $WslWatchdogPath) (New-BootAndRepeatTriggers 3) $settings "Highest"
    }
}

# Sleep, wake (with its source), shutdown, unexpected reboot and crash events, so
# the next time the PC disappears the log says how.
$powerLogBody = @"
# Managed by agent-box. Appends sleep, wake, shutdown and crash events to $PowerEventsLog.
`$log = '$PowerEventsLog'
`$last = '$PowerEventsLog.last'
`$since = (Get-Date).AddDays(-30)
if (Test-Path `$last) { `$since = [datetime]::Parse((Get-Content `$last -Raw).Trim(), `$null, 'RoundtripKind') }
`$filter = @{ LogName = 'System'; Id = 1, 41, 42, 107, 1001, 1074, 6005, 6006, 6008; StartTime = `$since }
`$events = @(Get-WinEvent -FilterHashtable `$filter -ErrorAction SilentlyContinue |
    Where-Object { `$_.TimeCreated -gt `$since -and `$_.ProviderName -match 'Kernel-Power|User32|EventLog|Power-Troubleshooter|WER-SystemErrorReporting' } |
    Sort-Object TimeCreated)
foreach (`$e in `$events) {
    `$text = ("`$(`$e.Message)" -replace '\s+', ' ').Trim()
    if (`$text.Length -gt 300) { `$text = `$text.Substring(0, 300) }
    `$source = `$e.ProviderName -replace '^Microsoft-Windows-', ''
    Add-Content -Path `$log -Value (`$e.TimeCreated.ToString('s') + '  ' + `$source + ' ' + `$e.Id + '  ' + `$text)
}
if (`$events.Count -gt 0) { Set-Content -Path `$last -Value `$events[-1].TimeCreated.ToString('o') }
"@

Step "Power events log task ($PowerEventsLog, boot + hourly)" {
    (Test-ManagedScript $PowerLogPath $powerLogBody) -and (Test-Task $PowerLogTask)
} {
    Write-ManagedScript $PowerLogPath $powerLogBody
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1))
    )
    Register-ScheduledTask -TaskName $PowerLogTask -Action (New-ScriptAction $PowerLogPath) `
        -Trigger $triggers -User "SYSTEM" -RunLevel Highest -Force | Out-Null
}

# Opt-in (-SleepWhenIdle on): Wake-on-LAN over Wi-Fi isn't proven yet, and a PC that
# sleeps without waking is gone until someone presses the button. It only sleeps
# when agents are on, nobody is logged in to Windows or connected over SSH, and WSL
# reports no CI job, no working Claude and no heavy load (agent-box _busy).
$idleSleepBody = @"
# Managed by agent-box. Puts the PC to sleep (S3) after $IdleMinutes idle minutes.
$pausedCheck
$taskHelpers
`$since = '$DataDir\idle-since'
function Get-BusyReason {
    if (Get-Process explorer -ErrorAction SilentlyContinue) { return 'someone is logged in to Windows' }
    if (@(Get-Process sshd, sshd-session -ErrorAction SilentlyContinue).Count -gt 1) { return 'an SSH session to Windows is open' }
    `$r = Invoke-Wsl '-d $Distro --cd ~ --exec bash -lc "agent-box _busy"' 60
    if (`$r.Code -eq 0) { return "WSL: `$(`$r.Output)" }
    if (`$r.Code -ne 1) { return "WSL did not answer (exit `$(`$r.Code))" }
    `$null
}
`$reason = Get-BusyReason
if (`$reason) {
    if (Test-Path `$since) { Write-Log "idle sleep: busy again (`$reason)" }
    Remove-Item `$since -Force -ErrorAction SilentlyContinue
    exit 0
}
if (-not (Test-Path `$since)) {
    Set-Content `$since (Get-Date -Format o)
    Write-Log 'idle sleep: nothing running; sleeping if it stays so for $IdleMinutes min'
    exit 0
}
`$idle = (Get-Date) - [datetime]::Parse((Get-Content `$since -Raw).Trim(), `$null, 'RoundtripKind')
if (`$idle.TotalMinutes -lt $IdleMinutes) { exit 0 }
Remove-Item `$since -Force
Write-Log "idle sleep: idle for `$([int]`$idle.TotalMinutes) min, going to sleep"
& rundll32.exe 'powrprof.dll,SetSuspendState' '0,1,0'
"@

if ($SleepWhenIdle -eq "on") {
    Step "Idle sleep task (sleeps after $IdleMinutes idle minutes, checks every 10 min)" {
        (Test-ManagedScript $IdleSleepPath $idleSleepBody) -and (Test-Task $IdleSleepTask)
    } {
        Write-ManagedScript $IdleSleepPath $idleSleepBody
        if (-not (Test-Task $IdleSleepTask)) {
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-UserTask $IdleSleepTask (New-ScriptAction $IdleSleepPath) (New-BootAndRepeatTriggers 10) $settings "Highest"
        }
    }
    $script:Notes.Add("Sleep when idle is on: test that 'ether-wake' from the router wakes the PC (README -> Sleep when idle).")
} else {
    Step "No idle sleep task (sleep when idle is off)" { -not (Test-Task $IdleSleepTask) } {
        Unregister-ScheduledTask -TaskName $IdleSleepTask -Confirm:$false
        Remove-Item $IdleSleepPath -Force -ErrorAction SilentlyContinue
    }
}

$settingsBody = "# Managed by agent-box.`r`nSleepWhenIdle=$SleepWhenIdle`r`nIdleMinutes=$IdleMinutes"
Step "Settings saved to $SettingsFile" { Test-ManagedScript $SettingsFile $settingsBody } {
    Write-ManagedScript $SettingsFile $settingsBody
}

Write-Host ""
Write-Host ("{0} ok - {1} installed - {2} missing - {3} failed" -f `
    $Counts.ok, $Counts.installed, $Counts.missing, $Counts.failed)
if ($Notes.Count -gt 0) {
    Write-Host ""
    Write-Host "Manual steps:"
    $Notes | Select-Object -Unique | ForEach-Object { Write-Host "  - $_" }
}
if (-not $Install -and $Counts.missing -gt 0) {
    Write-Host ""
    Write-Host "Rerun with -Install to fix missing items." -ForegroundColor Yellow
}
if ($Counts.missing -gt 0 -or $Counts.failed -gt 0) { exit 1 }
