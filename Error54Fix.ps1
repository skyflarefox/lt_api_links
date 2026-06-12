# LuaTools - Error 54 Fix (Steam appcache) By Skyflare
# Run as Administrator | discord.gg/luatools

$Host.UI.RawUI.WindowTitle = "LuaTools | Error 54 Fix"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null
$ProgressPreference = 'SilentlyContinue'

$CacheFiles   = @("appinfo.vdf", "packageinfo.vdf", "packcode.vdf", "version")
$DefaultSteam = "C:\Program Files (x86)\Steam"

function Write-Log {
    param([string]$Level, [string]$Message, [switch]$Inline)

    $time = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level.ToUpper()) {
        "OK"   { "Green"  }
        "INFO" { "Cyan"   }
        "ERR"  { "Red"    }
        "WARN" { "Yellow" }
        default { "White" }
    }

    $prefix = if ($Inline) { "`r[$time] " } else { "[$time] " }
    Write-Host $prefix -ForegroundColor DarkCyan -NoNewline
    Write-Host "[$($Level.ToUpper())] $Message" -ForegroundColor $color -NoNewline:$Inline
}

function Get-SteamPath {
    $found = @()

    try {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -EA SilentlyContinue
        if ($reg.InstallPath) { $found += $reg.InstallPath }
    } catch {}

    try {
        $reg = Get-ItemProperty "HKCU:\Software\Valve\Steam" -EA SilentlyContinue
        if ($reg.SteamPath) { $found += $reg.SteamPath -replace '\\\\', '\' }
    } catch {}

    if (Test-Path $DefaultSteam) { $found += $DefaultSteam }

    $found = $found | Select-Object -Unique | Where-Object { Test-Path $_ }

    if ($found.Count -eq 0) {
        Write-Log "WARN" "Steam not found in registry. Falling back to default path."
        return $DefaultSteam
    }

    Write-Log "OK" "Steam found at: $($found[0])"
    return $found[0]
}

function Clear-SteamCache {
    param([string]$Folder)

    if (-not (Test-Path $Folder)) {
        Write-Log "WARN" "Folder not found, skipping: $Folder"
        return
    }

    Write-Log "INFO" "Scanning: $Folder"

    foreach ($file in $CacheFiles) {
        $path = Join-Path $Folder $file

        if (Test-Path $path) {
            try {
                Remove-Item $path -Force -EA Stop
                Write-Log "OK" "Deleted: $path"
                $script:deleted++
            } catch {
                Write-Log "ERR" "Could not delete: $path"
            }
        }
    }
}

Write-Log "INFO" "Looking for Steam installation..."
$steamPath = Get-SteamPath
Write-Host ""

Write-Log "INFO" "Shutting down Steam..."
Get-Process "steam" -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Write-Host ""

Write-Log "INFO" "Clearing cache files..."
Write-Host ""

$deleted = 0
$defaultCache = Join-Path $DefaultSteam "appcache"
$steamCache   = Join-Path $steamPath    "appcache"

Clear-SteamCache $defaultCache

if ($steamCache -ne $defaultCache) {
    Clear-SteamCache $steamCache
}

Write-Host ""

if ($deleted -gt 0) {
    Write-Log "OK" "$deleted file(s) removed successfully."
} else {
    Write-Log "WARN" "No cache files found. They may have already been cleared."
}

Write-Host ""
Write-Log "INFO" "Restarting Steam..."
Start-Process (Join-Path $steamPath "steam.exe") -ArgumentList "-clearbeta"

Write-Host ""
Write-Log "INFO" "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
exit
