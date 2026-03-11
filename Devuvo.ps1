param (
    [Parameter(Mandatory=$false)]
    [string]$AppID
)

# Self-elevate to Administrator if not already running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($AppID) { $argList += " -AppID $AppID" }
    Start-Process powershell -Verb RunAs -ArgumentList $argList -ErrorAction SilentlyContinue
    exit
}

if ([string]::IsNullOrWhiteSpace($AppID)) {
    $AppID = Read-Host "Enter Steam AppID"
}

# ---- Report data collection ----
$reportData = [ordered]@{
    AppID              = $AppID
    GameName           = "N/A"
    Installed          = $false
    FolderSize         = "N/A"
    MainExe            = "N/A"
    ExeSize            = "N/A"
    HasGoldberg        = $false
    GoldbergFiles      = @()
    UpdatesDisabled    = $false
    LuaFileFound       = $false
    WindowsUpdateBlocked = $false
}

Write-Host "Looking for Steam installation..." -ForegroundColor Cyan

# 1. Find Steam Path and Library Folders
$steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
if (-not $steamPath) {
    Write-Host "[-] Could not find Steam installation registry key." -ForegroundColor Red
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

$libraryFoldersPath = Join-Path $steamPath "steamapps\libraryfolders.vdf"
$libraries = @($steamPath)

if (Test-Path $libraryFoldersPath) {
    $content = Get-Content $libraryFoldersPath -Raw
    $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
    foreach ($match in $matches) {
        $libPath = $match.Groups[1].Value.Replace("\\", "\")
        if ($libPath -notin $libraries) {
            $libraries += $libPath
        }
    }
}

Write-Host "Scanning $($libraries.Count) Steam library folders..." -ForegroundColor Cyan

# 2. Check if AppID is installed
$installDir = $null
$gameName = $null

foreach ($lib in $libraries) {
    $manifestPath = Join-Path $lib "steamapps\appmanifest_$AppID.acf"
    if (Test-Path $manifestPath) {
        $manifestContent = Get-Content $manifestPath -Raw
        
        $installDirNameMatch = [regex]::Match($manifestContent, '"installdir"\s+"([^"]+)"')
        $nameMatch = [regex]::Match($manifestContent, '"name"\s+"([^"]+)"')
        
        if ($installDirNameMatch.Success) {
            $installDir = Join-Path $lib "steamapps\common\$($installDirNameMatch.Groups[1].Value)"
            if ($nameMatch.Success) {
                $gameName = $nameMatch.Groups[1].Value
            }
            break
        }
    }
}

$gameInstalled = $installDir -and (Test-Path $installDir)

if ($gameInstalled) {
    $reportData.Installed = $true
    $reportData.GameName = $gameName
    Write-Host "[+] Found Game: $gameName" -ForegroundColor Green
    Write-Host "[+] Install Directory: $installDir" -ForegroundColor Green

    # Folder size
    $folderSize = (Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($folderSize -ge 1GB) {
        $folderSizeStr = "{0:N2} GB" -f ($folderSize / 1GB)
    } elseif ($folderSize -ge 1MB) {
        $folderSizeStr = "{0:N2} MB" -f ($folderSize / 1MB)
    } else {
        $folderSizeStr = "{0:N2} KB" -f ($folderSize / 1KB)
    }
    $reportData.FolderSize = $folderSizeStr
    Write-Host "[+] Folder Size: $folderSizeStr" -ForegroundColor Green

    # Main exe size
    $excludePattern = "(?i)CrashHandler|CrashReport|unins.*|vcredist.*|dxwebsetup|dotnet.*|physx.*|oalinst|cefclient|vc_redist.*"
    $mainExe = Get-ChildItem -Path $installDir -Recurse -Filter "*.exe" -File -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.Name -notmatch $excludePattern -and 
            $_.FullName -notmatch "(?i)\\(_CommonRedist|_Redist)\\.*" 
        } | Sort-Object Length -Descending | Select-Object -First 1
    if ($mainExe) {
        if ($mainExe.Length -ge 1GB) {
            $exeSizeStr = "{0:N2} GB" -f ($mainExe.Length / 1GB)
        } elseif ($mainExe.Length -ge 1MB) {
            $exeSizeStr = "{0:N2} MB" -f ($mainExe.Length / 1MB)
        } else {
            $exeSizeStr = "{0:N2} KB" -f ($mainExe.Length / 1KB)
        }
        $reportData.MainExe = $mainExe.Name
        $reportData.ExeSize = $exeSizeStr
        Write-Host "[+] Main EXE ($($mainExe.Name)) Size: $exeSizeStr" -ForegroundColor Green
    } else {
        Write-Host "[-] No executable found in game directory." -ForegroundColor Yellow
    }

    # 3. Goldberg scan
    Write-Host "`n[*] Scanning for Goldberg Emulator files..." -ForegroundColor Cyan
    $goldbergIndicators = @("steam_settings", "steam_interfaces.txt", "coldclientloader.ini", "local_save.txt")
    $foundGoldberg = $false

    foreach ($indicator in $goldbergIndicators) {
        $targetPath = Join-Path $installDir $indicator
        if (Test-Path $targetPath) {
            Write-Host "    [!] WARNING: Found Goldberg specific file/folder: $indicator" -ForegroundColor Yellow
            $foundGoldberg = $true
            $reportData.GoldbergFiles += $indicator
        }
    }

    $steamDlls = Get-ChildItem -Path $installDir -Recurse -Include "steam_api.dll", "steam_api64.dll" -ErrorAction SilentlyContinue
    foreach ($dll in $steamDlls) {
        try {
            $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll.FullName)
            if ($versionInfo.ProductName -match "Goldberg" -or $versionInfo.CompanyName -match "Goldberg" -or $versionInfo.FileDescription -match "Goldberg") {
                Write-Host "    [!] WARNING: Found Goldberg patched DLL: $($dll.Name) at $($dll.DirectoryName)" -ForegroundColor Yellow
                $foundGoldberg = $true
                $reportData.GoldbergFiles += "$($dll.Name) (patched DLL)"
            }
        } catch {}
    }

    $reportData.HasGoldberg = $foundGoldberg
    if (-not $foundGoldberg) {
        Write-Host "    [+] No obvious Goldberg files detected." -ForegroundColor Green
    }
} else {
    Write-Host "[~] AppID $AppID is not installed on this system. Skipping install checks..." -ForegroundColor Yellow
    Write-Host "[~] Will still attempt to disable updates in stplug-in." -ForegroundColor Yellow
}

# 4. stplug-in lua modification
Write-Host "`n[*] Scanning for .lua files in stplug-in to disable updates/decryption..." -ForegroundColor Cyan

$stpluginDir = Get-ChildItem -Path $steamPath -Directory -Filter "stplug-in" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1

if ($stpluginDir) {
    Write-Host "    [+] Found stplug-in directory at: $($stpluginDir.FullName)" -ForegroundColor Green
    
    $targetLuaFile = Join-Path $stpluginDir.FullName "$AppID.lua"
    if (Test-Path $targetLuaFile) {
        $luaFiles = @(Get-Item $targetLuaFile)
    } else {
        $luaFiles = Get-ChildItem -Path $stpluginDir.FullName -Filter "*.lua" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne "Steamtools.lua" -and (Get-Content $_.FullName -Raw) -match "addappid\(\s*$AppID\b"
        }
    }
} else {
    Write-Host "    [-] Steam stplug-in directory not found within Steam installation." -ForegroundColor Red
    $luaFiles = @()
}

$modifiedFilesCount = 0

foreach ($luaFile in $luaFiles) {
    $reportData.LuaFileFound = $true
    $content = Get-Content $luaFile.FullName
    $modified = $false
    $newContent = @()
    $alreadyConfigured = $true
    
    foreach ($line in $content) {
        if ($line -match "^\s*--\s*(addappid\(.*)") {
            $newContent += $matches[1]
            $modified = $true
            $alreadyConfigured = $false
        } 
        elseif (($line -match "(?i)decryption.*key" -or $line -match "(?i)setManifestid\(") -and $line -notmatch "^\s*--") {
            $newContent += "-- $line"
            $modified = $true
            $alreadyConfigured = $false
        } else {
            $newContent += $line
        }
    }
    
    # Check if setManifestid lines exist and are already commented = updates disabled
    $luaRaw = Get-Content $luaFile.FullName -Raw
    if ($luaRaw -match "(?m)^\s*--\s*setManifestid\(" -or ($luaRaw -notmatch "setManifestid\(")) {
        $reportData.UpdatesDisabled = $true
    }
    
    if ($modified) {
        try {
            $newContent | Set-Content $luaFile.FullName
            Write-Host "    [+] Modified update/decryption/depot lines in: $($luaFile.Name)" -ForegroundColor Green
            $modifiedFilesCount++
            $reportData.UpdatesDisabled = $true
        } catch {
            Write-Host "    [-] Failed to write to $($luaFile.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "    [~] No changes needed in: $($luaFile.Name) (already configured)" -ForegroundColor DarkGray
    }
}

if ($luaFiles.Count -eq 0) {
    Write-Host "    [-] No .lua file found for AppID $AppID in stplug-in." -ForegroundColor Yellow
}

Write-Host "`n[*] Done! Modified $modifiedFilesCount .lua files." -ForegroundColor Cyan

# 5. Windows Update Blocker
Write-Host "`n[*] Checking Windows Update status..." -ForegroundColor Cyan

$wuauserv = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
$wuMedic = Get-Service -Name "WaaSMedicSvc" -ErrorAction SilentlyContinue
$updateOrch = Get-Service -Name "UsoSvc" -ErrorAction SilentlyContinue

$updateBlocked = $true
$wuDetails = @()

foreach ($svcInfo in @(
    @{ Name = "Windows Update (wuauserv)"; Svc = $wuauserv },
    @{ Name = "Windows Update Medic (WaaSMedicSvc)"; Svc = $wuMedic },
    @{ Name = "Update Orchestrator (UsoSvc)"; Svc = $updateOrch }
)) {
    $svc = $svcInfo.Svc
    if ($svc) {
        $startType = $svc.StartType
        $status = $svc.Status
        if ($startType -eq "Disabled" -and $status -eq "Stopped") {
            Write-Host "    [+] $($svcInfo.Name): Disabled & Stopped" -ForegroundColor Green
            $wuDetails += "$($svcInfo.Name): Disabled & Stopped"
        } else {
            Write-Host "    [!] $($svcInfo.Name): $status (StartType: $startType)" -ForegroundColor Yellow
            $wuDetails += "$($svcInfo.Name): $status (StartType: $startType)"
            $updateBlocked = $false
        }
    } else {
        Write-Host "    [~] $($svcInfo.Name): Service not found (OK)" -ForegroundColor DarkGray
        $wuDetails += "$($svcInfo.Name): Not found"
    }
}

if ($updateBlocked) {
    Write-Host "`n    [+] Windows Update is BLOCKED." -ForegroundColor Green
    $reportData.WindowsUpdateBlocked = $true
} else {
    Write-Host "`n    [!] Windows Update is NOT fully blocked." -ForegroundColor Yellow
    $choice = Read-Host "    Do you want to disable Windows Update services now? (Y/N)"
    if ($choice -match "^[Yy]") {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Host "    [-] Administrator privileges required to disable Windows Update." -ForegroundColor Red
            Write-Host "    [-] Please re-run this script as Administrator." -ForegroundColor Red
        } else {
            foreach ($svcName in @("wuauserv", "WaaSMedicSvc", "UsoSvc")) {
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($svc) {
                    try {
                        if ($svc.Status -ne "Stopped") {
                            Stop-Service -Name $svcName -Force -ErrorAction Stop
                        }
                        Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
                        if ($svcName -eq "WaaSMedicSvc") {
                            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName" -Name "Start" -Value 4 -ErrorAction SilentlyContinue
                        }
                        Write-Host "    [+] Disabled $svcName" -ForegroundColor Green
                    } catch {
                        Write-Host "    [-] Failed to disable ${svcName}: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
            Write-Host "`n    [+] Windows Update services have been disabled." -ForegroundColor Green
            $reportData.WindowsUpdateBlocked = $true
        }
    } else {
        Write-Host "    [~] Skipped. Windows Update services left unchanged." -ForegroundColor DarkGray
    }
}

# 6. Upload report to rTS Paste Service
Write-Host "`n[*] Uploading scan report to paste service..." -ForegroundColor Cyan

$jsonReport = [ordered]@{
    generated   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    appid       = $reportData.AppID
    game_name   = $reportData.GameName
    installed   = $reportData.Installed
    folder_size = $reportData.FolderSize
    main_exe    = $reportData.MainExe
    exe_size    = $reportData.ExeSize
    has_goldberg      = $reportData.HasGoldberg
    goldberg_files    = $reportData.GoldbergFiles
    lua_file_found    = $reportData.LuaFileFound
    updates_disabled  = $reportData.UpdatesDisabled
    windows_update_blocked = $reportData.WindowsUpdateBlocked
    windows_update_services = $wuDetails
} | ConvertTo-Json -Depth 3

try {
    $tempFile = [System.IO.Path]::GetTempFileName()
    $jsonReport | Set-Content -Path $tempFile -Encoding UTF8

    $headers = @{
        "Linx-Randomize" = "yes"
        "Accept" = "application/json"
    }
    
    $fileBytes = [System.IO.File]::ReadAllBytes($tempFile)
    $response = Invoke-RestMethod -Uri "https://paste.rtech.support/upload/report.json" -Method Put -Headers $headers -Body $fileBytes -ContentType "application/json"
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($response.url) {
        $pasteUrl = $response.url
        # Extract just the code from the URL (e.g. mc779imw from https://paste.rtech.support/mc779imw.txt)
        $pasteCode = ($pasteUrl -split '/')[-1] -replace '\.[^.]+$', ''
        
        Write-Host "`n    [+] Report uploaded successfully!" -ForegroundColor Green
        Write-Host "    [+] Paste URL:  $pasteUrl" -ForegroundColor Cyan
        Write-Host "    [+] Paste Code: $pasteCode" -ForegroundColor Cyan
        Write-Host "`n    Share the code '$pasteCode' with support staff." -ForegroundColor White
    } else {
        Write-Host "    [-] Upload succeeded but no URL returned." -ForegroundColor Yellow
        Write-Host "    Response: $($response | ConvertTo-Json -Compress)" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "    [-] Failed to upload report: $($_.Exception.Message)" -ForegroundColor Red
}

# 7. Restart Steam
Write-Host "`nPress any key to restart Steam..." -ForegroundColor Yellow
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

Write-Host "`nRestarting Steam..." -ForegroundColor Cyan
Stop-Process -Name "steam" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if ($steamPath) {
    Start-Process -FilePath (Join-Path $steamPath "steam.exe")
} else {
    Write-Host "[-] Could not find Steam executable to restart." -ForegroundColor Red
}
