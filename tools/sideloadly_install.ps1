# Install an IPA through the running Sideloadly GUI, without a mouse or a human.
#
# How it works (verified 12.11.2026, Sideloadly v0.72, iPhone 15 Pro Max / iOS 27.2.1):
#   1. `sideloadly.exe <ipa>` does not need any flags: it hands the path to the
#      already running instance, and the window shows the file name in its label.
#   2. The window is a Qt application, so UI Automation sees real controls:
#      QPushButton "Start" supports InvokePattern — one call starts signing and
#      installing, no password prompt when the session is remembered.
#   3. Progress lives in two QLabel texts: "Installing...", "91%", then "Done."
#
# Exit codes: 0 — "Done.", 1 — error reported in the UI, 2 — timeout,
#             3 — Apple ID password dialog appeared (a human must type it once).
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [int]$TimeoutSec = 300,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$UIA = [System.Windows.Automation.AutomationElement]

function Get-SideloadlyWindow {
    $proc = Get-Process sideloadly -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($null -eq $proc) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($UIA::ProcessIdProperty, $proc.Id)
    $wins = $UIA::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    if ($wins.Count -eq 0) { return $null }
    return @{ Process = $proc; Windows = $wins }
}

function Get-WindowText {
    param($window)
    $textCond = New-Object System.Windows.Automation.PropertyCondition(
        $UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $parts = @()
    foreach ($t in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)) {
        $n = $t.Current.Name
        if ($n -and $n.Trim().Length -gt 0) { $parts += $n.Trim() }
    }
    return ($parts -join " | ")
}

if (-not (Test-Path -LiteralPath $Ipa)) { Write-Error "IPA not found: $Ipa"; exit 1 }
$Ipa = (Resolve-Path -LiteralPath $Ipa).Path
$exe = "C:\Users\lenov\AppData\Local\Sideloadly\sideloadly.exe"
if (-not (Test-Path -LiteralPath $exe)) { Write-Error "Sideloadly not found: $exe"; exit 1 }

$state = Get-SideloadlyWindow
if ($null -eq $state) {
    Start-Process -FilePath $exe | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $state = Get-SideloadlyWindow
        if ($null -ne $state) { break }
    }
    if ($null -eq $state) { Write-Error "Sideloadly window did not appear"; exit 2 }
}

# Hand the file to the running instance; without arguments the exe only raises it.
& $exe $Ipa | Out-Null
# Qt may insert zero-width spaces into long labels (e.g. "ScanLab-0.15.4.ipa"),
# so strip invisible formatting characters before comparing.
function Get-CleanText {
    param([string]$Text)
    return [regex]::Replace($Text, "[\u200B-\u200F\uFEFF]", "")
}
$expected = [IO.Path]::GetFileName($Ipa)
$deadline = (Get-Date).AddSeconds(30)
$loaded = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $text = Get-CleanText (Get-WindowText -window $state.Windows[0])
    if ($text -like "*$expected*") { $loaded = $true; break }
}
if (-not $loaded) { Write-Error "Sideloadly did not pick up $expected"; exit 2 }

$nameCond = New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, "Start")
$start = $null
foreach ($w in $state.Windows) {
    $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
    if ($null -ne $btn) { $start = $btn; break }
}
if ($null -eq $start) { Write-Error "Start button not found"; exit 2 }

$pattern = $null
if (-not $start.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
    Write-Error "Start button does not support InvokePattern"; exit 2
}
$pattern.Invoke()

# Watch the labels: any progress line means the run started; "Done." ends it.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$lastText = ""
$sawProgress = $false
$result = "timeout"
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $state = Get-SideloadlyWindow
    if ($null -eq $state) { $result = "window closed"; break }
    $text = Get-WindowText -window $state.Windows[0]
    if ($text -ne $lastText) { $lastText = $text; Write-Output ("  " + $text) }
    if ($text -match "Installing|Signing|Uploading|Preparing|Processing|%") { $sawProgress = $true }
    if ($text -match "password|Password") { $result = "password"; break }
    if ($text -match "ERROR|Error|failed|Could not|Incorrect|wrong") { $result = "error"; break }
    if ($sawProgress -and $text -match "Done\.") { $result = "done"; break }
}

$code = switch ($result) {
    "done" { 0 }
    "password" { 3 }
    "error" { 1 }
    default { 2 }
}

if ($Json) {
    [pscustomobject]@{ ipa = $Ipa; result = $result; exit = $code; last = $lastText } |
        ConvertTo-Json -Compress
} else {
    "Результат: $result"
}
exit $code
