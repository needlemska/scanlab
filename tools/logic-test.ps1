# Локальные тесты логики ScanLab на Windows — без телефона, Mac и CI.
#
# Зачем: черновик логики (ракурсы, покрытие, подсказки) проверяется компилятором
# Swift и запуском за секунды. Раньше каждая такая ошибка стоила полного раунда
# сборки в GitHub Actions (5–10 минут) и сборки IPA.
#
# Что нужно: Swift-тулчейн для Windows (swift.org). Проверка:
#   swift --version
#
# Запуск:
#   powershell -File tools/logic-test.ps1   (или pwsh -File, если стоит PowerShell 7)
#
# Ограничение: тестируются только файлы без ARKit/UIKit (сейчас — Core/ScanCoach.swift).
# Всё, что тянет ARKit, UIKit, AVFoundation, компилируется только на macOS (CI).

[CmdletBinding()]
param(
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

function Find-Swiftc {
    $candidates = @()
    $toolchains = Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains"
    if (Test-Path $toolchains) {
        $candidates += Get-ChildItem $toolchains -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "usr\bin\swiftc.exe" }
    }
    $onPath = Get-Command swiftc -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$swiftc = Find-Swiftc
if (-not $swiftc) {
    Write-Host "Swift не найден. Поставьте тулчейн с https://swift.org/download/ (Windows)." -ForegroundColor Red
    exit 2
}

$binDir = Split-Path -Parent $swiftc
$env:PATH = "$binDir;" + $env:PATH

$sources = @(
    "Core\ScanCoach.swift",
    "tools\logic\main.swift"
)
foreach ($source in $sources) {
    if (-not (Test-Path $source)) {
        Write-Host "Нет файла: $source" -ForegroundColor Red
        exit 2
    }
}

$exe = Join-Path $env:TEMP "scanlab-logic-tests.exe"
if (Test-Path $exe) { Remove-Item $exe -Force }

$swiftVersion = (& swiftc --version 2>&1 | Select-Object -First 1)
Write-Host "swiftc: $swiftVersion" -ForegroundColor DarkGray
Write-Host "сборка: $($sources -join ', ')" -ForegroundColor DarkGray

& swiftc -O @sources -o $exe
if (-not (Test-Path $exe)) {
    Write-Host "Компиляция не удалась" -ForegroundColor Red
    exit 1
}

Write-Host ""
& $exe
$code = $LASTEXITCODE
Write-Host ""
if ($code -eq 0) {
    Write-Host "Логика в порядке." -ForegroundColor Green
} else {
    Write-Host "Есть провалы — смотрите строки FAIL выше." -ForegroundColor Red
}
if (-not $Keep -and (Test-Path $exe)) { Remove-Item $exe -Force }
exit $code
