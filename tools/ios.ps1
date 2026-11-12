#Requires -Version 5
<#
    tools\ios.ps1 — реальный iPhone на Windows-стенде без Mac.

    Тонкая обёртка: вся логика в python-файлах рядом (ios_status.py, ios_logs.py),
    потому что разбор вывода pymobiledevice3 средствами PowerShell 5.1 уже ломался
    (UTF-16 от `>`, кавычки в cmd, регистронезависимые имена переменных).

    Команды:
      status                 устройство, установленная версия, срок профиля, вердикт
      install [-Ipa path]    подписать и поставить IPA через Sideloadly (без мыши)
      selfcheck              прогнать самопроверку на телефоне и прочитать отчёт
      launch                 запустить ScanLab через DVT
      logs [-Seconds 20]     syslog live с фильтром по ScanLab
      pull [-Remote] [-Out]  забрать каталог из Documents приложения
      query                  метаданные установленного приложения
      ipa                    свежий ScanLab-unsigned.ipa из ветки builds
      help

    Пример:  .\tools\ios.ps1 install -Ipa .\dist\ScanLab-0.15.4.ipa
#>
param(
    [Parameter(Position = 0)][string]$Command = "status",
    [string]$Udid = "00008130-000A44C01443001C",
    [string]$BundleId = "com.scanlab.app.3CB3DRNXR2",
    [int]$Seconds = 20,
    [string]$Remote = "Documents/Scans",
    [string]$Out = ".\pulled",
    [string]$Ipa = ".\ScanLab-unsigned.ipa"
)

$ErrorActionPreference = "Stop"

$Py = $env:SCANLAB_PYTHON
if (-not $Py) { $Py = "C:\Users\lenov\AppData\Local\Programs\Python\Python310\python.exe" }
if (-not (Test-Path $Py)) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $Py = $cmd.Source } else { throw "Не найден python. Задайте `$env:SCANLAB_PYTHON." }
}
$env:PYTHONIOENCODING = "utf-8"

$Here = $PSScriptRoot
$StatusPy = Join-Path $Here "ios_status.py"
$LogsPy = Join-Path $Here "ios_logs.py"
$GetIpa = Join-Path $Here "..\get-ipa.ps1"

function Show-Help {
    @"
tools\ios.ps1 <команда> [параметры]

  status                 состояние устройства, версия приложения, срок профиля
  install                подписать и поставить IPA через Sideloadly (-Ipa путь)
  selfcheck              самопроверка на телефоне + чтение отчёта
  launch                 запуск ScanLab (developer dvt launch)
  logs                   живые логи с фильтром (-Seconds, -Out)
  pull                   забрать $Remote в $Out
  query                  метаданные приложения
  ipa                    скачать свежий IPA из ветки builds

Параметры: -Udid, -BundleId, -Seconds, -Remote, -Out, -Ipa
"@
}

switch ($Command.ToLower()) {
    "status" {
        & $Py $StatusPy --udid $Udid --bundle $BundleId
        exit $LASTEXITCODE
    }
    "install" {
        $installer = Join-Path $Here "sideloadly_install.ps1"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Ipa $Ipa
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        "--- проверка после установки ---"
        & $Py $StatusPy --udid $Udid --bundle $BundleId
        exit $LASTEXITCODE
    }
    "selfcheck" {
        & $Py (Join-Path $Here "ios_selfcheck.py") --udid $Udid --bundle $BundleId
        exit $LASTEXITCODE
    }
    "launch" {
        & $Py -m pymobiledevice3 developer dvt launch $BundleId --udid $Udid 2>&1 | Select-Object -Last 8
        exit $LASTEXITCODE
    }
    "logs" {
        & $Py $LogsPy --udid $Udid --seconds $Seconds --out $Out
        exit $LASTEXITCODE
    }
    "pull" {
        if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }
        & $Py -m pymobiledevice3 apps pull $BundleId $Remote $Out --udid $Udid
        "забрано в: $((Resolve-Path $Out).Path)"
        exit $LASTEXITCODE
    }
    "query" {
        $tmp = Join-Path $env:TEMP "scanlab_query.json"
        $proc = Start-Process -FilePath $Py -NoNewWindow -Wait -PassThru `
            -ArgumentList @("-m", "pymobiledevice3", "apps", "query", $BundleId, "--udid", $Udid) `
            -RedirectStandardOutput $tmp -RedirectStandardError ($tmp + ".err")
        [IO.File]::ReadAllText($tmp, (New-Object Text.UTF8Encoding($false)))
        exit $proc.ExitCode
    }
    "ipa" {
        & $GetIpa
        exit 0
    }
    default { Show-Help }
}
