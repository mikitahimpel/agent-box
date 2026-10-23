# agent-box on Windows. In an administrator PowerShell:
#
#   irm https://raw.githubusercontent.com/mikitahimpel/agent-box/main/install.ps1 | iex
#
# Gets agent-box into %USERPROFILE%\agent-box, sets up Windows (windows\setup.ps1),
# then runs the Linux install inside WSL. Safe to rerun; run it again whenever
# it asks you to reboot or open Ubuntu first.

& {
    $ErrorActionPreference = "Stop"
    $Repo   = "mikitahimpel/agent-box"
    $Dir    = Join-Path $env:USERPROFILE "agent-box"
    $Distro = "Ubuntu"
    $LinuxInstall = "curl -fsSL https://raw.githubusercontent.com/$Repo/main/install.sh | bash"

    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Run this in an administrator PowerShell (right-click PowerShell -> Run as administrator)." -ForegroundColor Red
        return
    }

    # A git checkout (from an earlier manual setup) is updated in place;
    # otherwise the folder is replaced with the latest download.
    if ((Test-Path (Join-Path $Dir ".git")) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        & git -C $Dir pull --ff-only
    } else {
        Write-Host "Downloading agent-box to $Dir"
        $zip = Join-Path $env:TEMP "agent-box.zip"
        $src = Join-Path $env:TEMP "agent-box-src"
        Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
        Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $zip $src
        Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item (Join-Path $src "agent-box-main") $Dir
        Remove-Item $zip, $src -Recurse -Force -ErrorAction SilentlyContinue
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir "windows\setup.ps1") -Install

    $ErrorActionPreference = "Continue"
    $linuxUser = "$(& wsl.exe -d $Distro -- whoami 2>$null)".Trim()
    if (-not $linuxUser -or $linuxUser -eq "root") {
        Write-Host ""
        Write-Host "Next: reboot if WSL was just installed, open Ubuntu from the Start menu once to" -ForegroundColor Yellow
        Write-Host "create your Linux user, then run this same command again." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Setting up WSL ($Distro, user $linuxUser)"
    & wsl.exe -d $Distro -- bash -lc $LinuxInstall

    # The first Linux run turns systemd on in /etc/wsl.conf, which needs a WSL restart.
    $pid1 = "$(& wsl.exe -d $Distro -- ps -p 1 -o comm= 2>$null)".Trim()
    & wsl.exe -d $Distro -- grep -q "systemd *= *true" /etc/wsl.conf 2>$null
    if ($LASTEXITCODE -eq 0 -and $pid1 -ne "systemd") {
        Write-Host ""
        Write-Host "Restarting WSL to turn on systemd, then finishing the Linux setup"
        & wsl.exe --shutdown
        & wsl.exe -d $Distro -- bash -lc $LinuxInstall
    }
}
