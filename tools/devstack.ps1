# Проверка стенда под разработку ScanLab: что есть, чего нет, что делать.
#
#   powershell -File tools\devstack.ps1            — краткая сводка
#   powershell -File tools\devstack.ps1 -Check     — то же плюс коды выхода
#
# Ничего не устанавливает и не меняет: только смотрит и говорит.
# Установка всего, что требует прав администратора, вынесена в DEVSTACK.md.

[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = "Continue"
$script:missing = @()
$script:adminNeeded = @()

function Show-Item {
    param([string]$Name, [bool]$Ok, [string]$Detail = "", [string]$Fix = "")

    $mark = if ($Ok) { "OK  " } else { "НЕТ " }
    $color = if ($Ok) { "Green" } else { "Yellow" }
    Write-Host ("{0} {1,-26} {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
    if (-not $Ok -and $Fix) { Write-Host ("     → " + $Fix) -ForegroundColor DarkGray }
}

function Find-Command($Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

Write-Host ""
Write-Host "ScanLab · стенд" -ForegroundColor Cyan
Write-Host ("папка:    {0}" -f $root) -ForegroundColor DarkGray
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) { Write-Host ("система:  {0} (build {1})" -f $os.Caption, $os.BuildNumber) -ForegroundColor DarkGray }
Write-Host ("python:   {0}" -f (Find-Command "python")) -ForegroundColor DarkGray
Write-Host ""

# --- то, без чего проект не двигается -------------------------------------
Write-Host "Основа" -ForegroundColor Cyan

$git = Find-Command "git"
Show-Item "git" ([bool]$git) $(if ($git) { (& git --version) } else { "" }) "winget install Git.Git"

if ($git) {
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    $sha = & git rev-parse --short HEAD 2>$null
    $dirty = (& git status --porcelain 2>$null | Measure-Object).Count
    Show-Item "репозиторий" ([bool]$branch) ("ветка {0} @ {1}, изменений {2}" -f $branch, $sha, $dirty)
}

$python = Find-Command "python"
Show-Item "python" ([bool]$python) $(if ($python) { (& python --version 2>&1) } else { "" }) "winget install Python.Python.3.12"

if ($python) {
    $numpy = & python -c "import numpy; print(numpy.__version__)" 2>$null
    Show-Item "numpy" ([bool]$numpy) ($numpy -join "") "python -m pip install --user numpy"
    $py3d = & python -c "print('ok')" 2>$null
    Show-Item "скрипты pc/" ([bool]$py3d) "pgm / photogrammetry / масштабы"
}

$gh = Find-Command "gh"
Show-Item "gh cli" ([bool]$gh) $(if ($gh) { (& gh --version 2>&1 | Select-Object -First 1) } else { "" }) "winget install GitHub.cli"

if ($gh) {
    $auth = & gh auth status 2>&1 | Out-String
    $authed = $auth -notmatch "not logged"
    Show-Item "gh вход" $authed $(if ($authed) { "готово" } else { "нет входа" }) "gh auth login"
    if (-not $authed) { $script:adminNeeded += "gh auth login (нужен браузер, один раз)" }
}

# --- сборка и проверка кода ----------------------------------------------
Write-Host ""
Write-Host "Сборка" -ForegroundColor Cyan

$swiftc = Find-Command "swiftc"
if (-not $swiftc) {
    $toolchains = Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains"
    if (Test-Path $toolchains) {
        $swiftc = Get-ChildItem $toolchains -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "usr\bin\swiftc.exe" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
}
Show-Item "swiftc (логика)" ([bool]$swiftc) $(if ($swiftc) { (& $swiftc --version 2>&1 | Select-Object -First 1) } else { "тесты логики только в CI" }) `
    "winget install --id Swift.Toolchain -e (нужен админ)"

$link = Find-Command "link.exe"
$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
}
Show-Item "MSVC (линковка)" ([bool]$link -or [bool]$vsPath) $(if ($vsPath) { $vsPath } else { "нет VC++ Build Tools" }) `
    "winget install --id Microsoft.VisualStudio.2022.BuildTools -e (нужен админ, workload VCTools)"

Show-Item "Xcode / Simulator" $false "только macOS, на Windows невозможно" ""

# --- телефон ---------------------------------------------------------------
Write-Host ""
Write-Host "Телефон" -ForegroundColor Cyan

$amd = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
Show-Item "Apple Mobile Device" ([bool]$amd) $(if ($amd) { $amd.Status } else { "нет iTunes" }) "winget install Apple.iTunes"

$sideloadly = @(
    "C:\Program Files\Sideloadly\Sideloadly.exe",
    (Join-Path $env:LOCALAPPDATA "Programs\Sideloadly\Sideloadly.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\SideloadlyPortable\sideloadly.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
Show-Item "Sideloadly" ([bool]$sideloadly) $(if ($sideloadly) { $sideloadly } else { "нет" }) `
    "winget install --id Sideloadly -e (или sideloadly.io)"

if ($python) {
    $pmd = (& python -m pymobiledevice3 version 2>$null | Select-Object -First 1)
    Show-Item "pymobiledevice3" ([bool]$pmd) $(if ($pmd) { $pmd } else { "нет" }) "python -m pip install --user pymobiledevice3"
}

# --- что делаем дальше -----------------------------------------------------
Write-Host ""
if ($Check) {
    Write-Host "Проверка закончена." -ForegroundColor Cyan
    if ($script:adminNeeded.Count -gt 0) {
        Write-Host "Требует ваших действий:" -ForegroundColor Yellow
        $script:adminNeeded | ForEach-Object { Write-Host ("  · " + $_) -ForegroundColor Yellow }
    }
}

exit 0
