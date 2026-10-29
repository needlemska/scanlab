# install.ps1 - проверка готовности и запуск установки ScanLab на iPhone.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Check     только диагностика
#   powershell -ExecutionPolicy Bypass -File install.ps1            проверка + запуск Sideloadly
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Watch     ... и ждать установки
#
# Скрипт ничего не подписывает сам: подпись делает Sideloadly вашим Apple ID.

param(
    [string]$Ipa = "",
    [switch]$Check,
    [switch]$Watch,
[switch]$WaitDevice,
    [int]$Minutes = 10
)

$ErrorActionPreference = "Continue"
$script:problems = 0

function Section([string]$text) { Write-Host ""; Write-Host $text -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "  OK   $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "  !    $text" -ForegroundColor Yellow }
function Bad([string]$text) { Write-Host "  FAIL $text" -ForegroundColor Red; $script:problems++ }

Section "1. IPA"
if (-not $Ipa) { $Ipa = Join-Path $PSScriptRoot "ScanLab-unsigned.ipa" }
if (Test-Path $Ipa) {
    $file = Get-Item $Ipa
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.Substring(0, 16)
    Ok ("{0} - {1:N0} байт, {2}, sha256 {3}..." -f $file.Name, $file.Length, $file.LastWriteTime, $hash)

    $py = $null
    foreach ($candidate in @("py -3.12", "py -3", "python")) {
        $parts = $candidate.Split(" ")
        $cmd = Get-Command $parts[0] -ErrorAction SilentlyContinue
        if ($cmd) {
            $py = $candidate
            break
        }
    }
    if ($py) {
        $code = @'
import sys, zipfile, plistlib
try:
    z = zipfile.ZipFile(sys.argv[1])
    p = plistlib.loads(z.read("Payload/ScanLab.app/Info.plist"))
    print("%s (build %s), %s" % (p["CFBundleShortVersionString"], p["CFBundleVersion"], p["CFBundleIdentifier"]))
except Exception as exc:
    print("не прочитать: %s" % exc)
'@
        $tmp = Join-Path $env:TEMP "scanlab_ver.py"
        [IO.File]::WriteAllText($tmp, $code, (New-Object System.Text.UTF8Encoding($false)))
        $out = & cmd /c "$py `"$tmp`" `"$($file.FullName)`"" 2>&1
        Ok ("версия: " + ($out -join " "))
    }
} else {
    Bad "нет файла $Ipa - соберите IPA в GitHub Actions (ветка builds) и положите рядом"
}

Section "2. Sideloadly"
$sideloadly = Join-Path $env:LOCALAPPDATA "Sideloadly\sideloadly.exe"
if (Test-Path $sideloadly) {
    $info = (Get-Item $sideloadly).VersionInfo
    $ver = $info.FileVersion; if (-not $ver) { $ver = $info.ProductVersion }
    if (-not $ver) { $ver = "версия не указана" }
    Ok "Sideloadly $ver - $sideloadly"
} else {
    Bad "Sideloadly не найден - поставьте с sideloadly.io"
}

Section "3. Драйверы Apple"
$service = Get-Service "Apple Mobile Device Service" -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -eq "Running") { Ok "Apple Mobile Device Service работает" }
    else { Warn "служба $($service.Status) - перезапустите «Apple Devices» или перезагрузите ПК" }
} else {
    Warn "службы Apple Mobile Device Service нет - поставьте «Apple Devices» из Microsoft Store"
}

Section "4. Телефон"
$probeDevices = {
    @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "USB\VID_05AC*" })
}
if ($WaitDevice -and (@(& $probeDevices)).Count -eq 0) {
    Write-Host "  Жду кабель: подключите iPhone и нажмите «Доверять» (до $Minutes мин, Ctrl+C - отмена)..." -ForegroundColor Cyan
    $deviceDeadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deviceDeadline -and (@(& $probeDevices)).Count -eq 0) {
        Start-Sleep -Seconds 3
    }
    if ((@(& $probeDevices)).Count -gt 0) {
        Write-Host "  телефон подключён" -ForegroundColor Green
        Start-Sleep -Seconds 2
    } else {
        Write-Host "  за $Minutes мин телефон так и не появился" -ForegroundColor Yellow
    }
}
$devices = @(& $probeDevices)
if ($devices.Count -gt 0) {
    Ok "устройств Apple по USB: $($devices.Count)"
} else {
    Bad "iPhone не виден по USB: кабель -> разблокировать -> «Доверять этому компьютеру»"
}

$lockdown = "C:\ProgramData\Apple\Lockdown"
$pairing = @(Get-ChildItem $lockdown -Filter "*.plist" -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match "^[0-9A-Fa-f]{8,}" })
if ($pairing.Count -gt 0) {
    $newest = $pairing | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Ok "сопряжение: $($newest.BaseName) ($($newest.LastWriteTime))"
} else {
    Warn "нет записи сопряжения - при первом подключении нажмите «Доверять» на телефоне"
}

Section "5. Установка"
if ($Check) {
    Write-Host ""
    if ($script:problems -eq 0) { Write-Host "Всё готово: запустите без -Check, чтобы открыть Sideloadly." -ForegroundColor Green }
    else { Write-Host "Проблем: $script:problems - см. строки FAIL/Warn выше." -ForegroundColor Yellow }
    exit $script:problems
}

$running = Get-Process sideloadly -ErrorAction SilentlyContinue
if ($running) {
    Ok "Sideloadly уже запущен (PID $($running.Id -join ',')) - перетащите IPA в окно, если он открыт без файла"
} else {
    if ($script:problems -gt 0) {
        Write-Host ""
        Write-Host "Запускать рано: сначала исправьте проблемы выше." -ForegroundColor Yellow
        exit $script:problems
    }
    Start-Process -FilePath $sideloadly -ArgumentList "`"$Ipa`"" -WorkingDirectory $env:TEMP
    Ok "Sideloadly запущен с $([IO.Path]::GetFileName($Ipa))"
}

Write-Host ""
Write-Host "Дальше в окне Sideloadly:" -ForegroundColor Cyan
Write-Host "  1. Apple ID и пароль приложения (appleid.apple.com -> Вход и безопасность -> Пароли приложений)"
Write-Host "  2. Start, затем код 2FA с телефона"
Write-Host "  3. На iPhone: Настройки -> Конфиденциальность и безопасность -> Режим разработчика -> вкл, перезагрузка"
Write-Host "  4. Настройки -> Основные -> VPN и управление устройством -> доверять сертификату"
Write-Host "  5. Подпись живёт 7 дней, данные в Documents/Scans переживают переподпись"

if ($Watch) {
    Section "6. Жду установку (до $Minutes мин)"
    $db = Join-Path $env:LOCALAPPDATA "Sideloadly\installations.db"
    $before = if (Test-Path $db) { (Get-Item $db).LastWriteTime } else { [datetime]::MinValue }
    $deadline = (Get-Date).AddMinutes($Minutes)
    $seen = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Path $db) {
            $after = (Get-Item $db).LastWriteTime
            if ($after -gt $before) {
                $seen = $true
                Write-Host "  $((Get-Date).ToString('HH:mm:ss')) база Sideloadly обновилась - установка идёт" -ForegroundColor Green
                $before = $after
            }
        }
        if (-not (Get-Process sideloadly -ErrorAction SilentlyContinue)) { break }
    }
    if ($seen) { Ok "активность была - проверьте «ScanLab» на телефоне" }
    else { Warn "активности не было: Sideloadly закрыт или установка не начиналась" }
}
