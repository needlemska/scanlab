#Requires -Version 5
<#
    Забирает собранный ScanLab-unsigned.ipa из ветки builds.

    Нужен потому, что на некоторых сетях (в частности у владельца проекта)
    хосты pipelines.githubusercontent.com / objects.githubusercontent.com
    недоступны и страница артефактов GitHub не скачивается. А git ходит
    через github.com:443, который доступен.

    Использование:  .\get-ipa.ps1
#>
param(
    [string]$Remote = "origin"
)

$ErrorActionPreference = "Stop"

git fetch $Remote builds
if ($LASTEXITCODE -ne 0) {
    throw "Не удалось получить ветку builds. Сборка ещё не завершилась или упала."
}

git checkout FETCH_HEAD -- ScanLab-unsigned.ipa
if ($LASTEXITCODE -ne 0) {
    throw "В ветке builds нет файла ScanLab-unsigned.ipa."
}

$file = Get-Item .\ScanLab-unsigned.ipa
"Готово: {0} ({1:N1} МБ), собрано {2:dd.MM.yyyy HH:mm}" -f `
    $file.Name, ($file.Length / 1MB), $file.LastWriteTime
"sha256: " + (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()

$info = git show FETCH_HEAD:BUILD.txt 2>$null
if ($LASTEXITCODE -eq 0) { "--- сборка ---`n$info" }

"`nДальше: перетащите ScanLab-unsigned.ipa в Sideloadly."
