# RUNBOOK — ScanLab на стенде `lenov`

Живой справочник: конкретные значения, команды и инциденты. Меняется по мере работы.
Дата последней сверки: **12.11.2026**.

## 1. Железо и ПО стенда

| Что | Значение |
|---|---|
| ОС | Windows, пользователь `lenov`, **без прав администратора** |
| Python | `C:\Users\lenov\AppData\Local\Programs\Python\Python310\python.exe` |
| pymobiledevice3 | 11.52.1, поставлен `--user` |
| Apple Mobile Device Service | Running |
| Sideloadly | `C:\Users\lenov\AppData\Local\Sideloadly\sideloadly.exe` |
| Данные Sideloadly | `C:\Users\lenov\AppData\Local\Sideloadly\` (`installations.db`, `sessions.json`, `cert-nabarnov@yandex.ru.pem`, `key.pem`) |
| Swift для Windows | на этом стенде **нет** (установка требует админа) → локальные Swift-тесты недоступны, только CI |
| ExecutionPolicy | `CurrentUser = RemoteSigned` → локальные `.ps1` не запускаются без `-ExecutionPolicy Bypass` |
| Репозиторий | `scanlab/` = `https://github.com/needlemska/scanlab`, `gh` залогинен как `needlemska` |

## 2. Телефон

| Что | Значение |
|---|---|
| Модель | iPhone16,2 (iPhone 15 Pro Max), arm64e |
| Имя | iPhone lenov |
| iOS | **27.2.1 (24B156)** |
| UDID | `00008130-000A44C01443001C` |
| Приложение | `com.scanlab.app.3CB3DRNXR2` (ALTBundleIdentifier `com.scanlab.app`) |
| Команда подписи | `3CB3DRNXR2` (свободный Apple ID `nabarnov@yandex.ru`) |
| Энтайтлменты | `get-task-allow: true` (debug-подпись, DVT-запуск возможен) |
| **Стоит на телефоне** | **0.11.0 (build 11)** — сильно старше `main` (0.15.3) |
| Профиль | выставлен 29.10.2026 16:49, TTL 7 дней → **истёк 05.11.2026 16:49 MSK** |

Следствие: приложение на телефоне **сейчас не запускается** — iOS не даёт стартовать процессу
с истёкшим профилем. Нужна переподпись свежим профилем (Sideloadly), и лучше сразу 0.15.3.

## 3. Быстрый статус

```powershell
cd scanlab
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 status   # вердикт по профилю
```

Без обёртки (то же самое, если .ps1 заблокирован):

```powershell
$py = "C:\Users\lenov\AppData\Local\Programs\Python\Python310\python.exe"
& $py tools\ios_status.py                     # подключение, версия, срок профиля
& $py -m pymobiledevice3 apps query com.scanlab.app.3CB3DRNXR2 --udid 00008130-000A44C01443001C
```

## 4. Сборка и получение IPA

Сборку запускает push в `main` (или `gh workflow run build -R needlemska/scanlab`), смотреть
`gh run list -R needlemska/scanlab --limit 3`. Артефакты GitHub на этой сети могут не открываться,
поэтому IPA берём из ветки `builds` через git:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\get-ipa.ps1   # IPA из ветки builds
Get-Content BUILD.txt                                               # run, commit, время сборки
```

Проверено 12.11.2026: `ScanLab-unsigned.ipa` = **0.15.3 (build 19)**, `run=48`, commit `75ff63e`,
sha256 `0ff7b6467bafbb23efb649199bcf853292c635f24f0d0bae723fc84fc6cde0bc`, 488 836 байт.
Внутри IPA **нет** `embedded.mobileprovision` — подпись добавляет Sideloadly.

## 5. Установка на телефон

1. `powershell -NoProfile -ExecutionPolicy Bypass -File .\get-ipa.ps1` — IPA в корне репозитория.
2. Открыть `C:\Users\lenov\AppData\Local\Sideloadly\sideloadly.exe`.
3. Перетащить `ScanLab-unsigned.ipa` в окно, убедиться, что выбран iPhone (UDID `00008130-…`).
4. Рядом с Apple ID должно стоять `nabarnov@yandex.ru`; поле Bundle ID — `com.scanlab.app`
   (Sideloadly сам добавит хвост `3CB3DRNXR2`).
5. Нажать **Start** и дождаться `Done`. Пароль/2FA — только человек.
6. Проверить: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 status` →
   версия должна совпасть с `BUILD.txt`.

Ограничения свободного Apple ID: профиль 7 дней, 3 приложения, 10 новых App ID в неделю.
Повторная установка с тем же bundle id слот не тратит.

## 6. Логи и запуск

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 launch        # DVT-запуск
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 logs -Seconds 20
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 pull          # Documents/Scans
```

Проверено 12.11.2026: `syslog live` отдаёт ~600–1500 строк в секунду (за 8 с — 11 924 строки,
файл в `logs/`, папка в `.gitignore`). Собственных логов приложение не пишет, поэтому совпадений
по фильтру `ScanLab` обычно 0 — это нормально, о запуске судят по `dvt`-командам ниже.

Если `dvt launch` отвечает
`DTXNsError: com.apple.dt.deviceprocesscontrolservice (code 2, … 'Request to launch … failed.')` —
почти всегда это истёкший/битый профиль, приложение удалено **или профиль разработчика ещё не
доверен** (`Настройки → Основные → VPN и управление устройством → Доверять`). Смотреть `status`.

### 6б. DVT напрямую: запуск с вкладкой, скриншот, выгрузка

`pymobiledevice3 developer dvt` даёт то, что раньше считалось недоступным без WDA:

```powershell
$py = "C:\Users\lenov\AppData\Local\Programs\Python\Python310\python.exe"
$udid = "00008130-000A44C01443001C"
$b = "com.scanlab.app.3CB3DRNXR2"

& $py -m pymobiledevice3 developer dvt process-id-for-bundle-id $b --udid $udid   # PID, 0 = не запущено
& $py -m pymobiledevice3 developer dvt launch $b --udid $udid --env "SCANLAB_TAB=4"  # Тест
& $py -m pymobiledevice3 developer dvt screenshot shot.png --udid $udid            # экран телефона
& $py -m pymobiledevice3 apps pull $b Scans .\pulled --documents --udid $udid      # Documents/Scans
```

Что проверено 12.11.2026 на 0.15.3 (build 19): `process-id-for-bundle-id` вернул `3096`,
`launch` — `Process launched with pid 3110`, `screenshot` снял вкладку LiDAR с активной камерой
и `v0.15.3 (19)` в шапке, `apps pull … Scans` ответил `OBJECT_NOT_FOUND` (сканов ещё нет).

Границы: DVT **не нажимает** на экран (нет UI-автоматизации), а `screenshot` на заблокированном
телефоне отдаёт локскрин (файл 8–9 МБ вместо 100–400 КБ) — сначала разблокировать.

## 7. Тесты без телефона

```powershell
$py = "C:\Users\lenov\AppData\Local\Programs\Python\Python310\python.exe"
$env:PYTHONIOENCODING = "utf-8"
& $py tools\tests\test_calibration.py         # 23 проверки: калибровка, масштаб, стол, images.txt
```

Последний замер (12.11.2026): `все 23 проверки ok` за ~1 с, Python 3.10.11, numpy 2.2.6.

Swift-логика (`Core/ScanCoach.swift` и т.п.) локально не собирается — на этом стенде нет
Swift-тулчейна. Её компиляцию и проверки подтверждает только CI-прогон (`check`).
Перед пушем полезен дешёвый гейт на грубые ошибки правок: баланс скобок в Swift-файлах
(`.scratch/check_braces.py` в рабочей папке стенда, 13 файлов).

## 7б. Симулятор iOS (единственный «эмулятор», доступный с Windows)

Установить iOS-эмулятор на Windows нельзя: Xcode Simulator существует только под macOS,
а «эмуляторы» вроде iPadian — это оболочка с веб-страницами, а не iOS. Реальный симулятор
запускается **на macOS-раннере GitHub Actions** (workflow `simulator-run`), его экран
приезжает скриншотами в артефакте `sim-out`.

```powershell
gh workflow run simulator-run -R needlemska/scanlab
gh run watch -R needlemska/scanlab --interval 20
gh run download <run-id> -R needlemska/scanlab -n sim-out -D .scratch/sim-out
```

Что этот прогон доказывает: код компилируется под iOS Simulator, приложение устанавливается,
стартует, рисует все вкладки (по одной на скриншот `tab-0…tab-4.png`), не падает на старте,
в логе нет исключений. Что он доказать **не может**: ARKit, LiDAR, камера, Object Capture и
фотограмметрия в симуляторе отсутствуют — AR-сцена чёрная, кнопка «Старт» ничего не снимает.
Значит, геометрия, съёмка и точность измерений проверяются только на телефоне.

Как это устроено внутри: `App/ScanLabApp.swift` держит выбранную вкладку в `@State`,
начальное значение берётся из переменной окружения `SCANLAB_TAB` (0…4) — так workflow
перезапускает приложение сразу на нужной вкладке без тапов. Разрешения (камера, микрофон,
фото, геолокация) выдаются через `xcrun simctl privacy … grant` до запуска, иначе системный
диалог закрывает половину экрана. Скриншот снимается в цикле, пока файл не станет больше
20 КБ: первый кадр после `simctl launch` иногда попадает на чёрную заставку запуска.

Проверено 12.11.2026 (v0.15.1, build 17, прогон 43208918729): все 5 вкладок рисуются;
без камеры вкладка «Фото» показывает «Камера недоступна» и алерт «Не удалось открыть камеру»,
приложение при этом не падает — это и есть польза симулятора: он ловит такие состояния UI.

## 8. Инциденты

### 2026-11-12. Приложение на телефоне не запускается — профиль истёк

- `account-appids.json` → `NearestTtl: 2026-11-05T13:49:42Z` (16:49 MSK);
  `installations.db` → установка 29.10.2026 16:49, `known_ttl = 7`.
- `developer dvt launch` → отказ (`code 2`, `Failed to launch process with bundle identifier`).
- Лечение: переподписать и поставить свежую сборку (Sideloadly → Start). Данные из
  `Documents/Scans` при переустановке с тем же bundle id сохраняются.

### 2026-11-12. `.ps1` не запускается: «is not digitally signed»

- `Get-ExecutionPolicy -List` → `CurrentUser = RemoteSigned`, а файлы из git не подписаны.
- Лечение: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 status`
  (или `Unblock-File` для конкретного файла без админа). Менять политику машины не нужно.

### 2026-11-12. `get-ipa.ps1` ставит IPA в индекс git

- `git checkout FETCH_HEAD -- ScanLab-unsigned.ipa` обходит `.gitignore` и делает файл staged (`A`).
- Исправлено в самом скрипте: сразу после `checkout` идёт `git reset -q -- ScanLab-unsigned.ipa`
  (коммит `a9b4818`). Если видите `A  ScanLab-unsigned.ipa` — скрипт старый, хватит
  `git reset -- ScanLab-unsigned.ipa`.

### 2026-11-12. Разбор вывода PowerShell'ом молча даёт пустые поля

- `$py = Invoke-Py …` и глобальный `$Py` (путь к python) — **одна и та же переменная**:
  PowerShell регистронезависим. После первого присваивания дальше запускается «объект».
- Вывод: парсить `pymobiledevice3` в PowerShell не надо. Логика живёт в `tools/ios_status.py`
  и `tools/ios_logs.py`, а `.ps1` только вызывает python.

### 2026-11-12. `pymobiledevice3 apps list` заливает контекст

- Команда печатает Info.plist **всех** приложений (сотни КБ, мусор от Яндекса и т.п.).
- Лечение: не вызывать без нужды; для одного приложения — `apps query <bundle-id>`.

### 2026-11-12. PowerShell `>` пишет UTF-16, `json.load` падает

- Симптом: `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 0`.
- Причина: `>` в PowerShell 5.1 создаёт UTF-16LE файл с BOM.
- Лечение: `cmd /c "… > file"` либо читать с определением кодировки:
  `raw.decode('utf-8', 'replace')` (в выводе pymobiledevice3 бывают cp1251-байты).

### 2026-11-12. `.ps1` с кириллицей не читается

- PowerShell 5.1 требует **UTF-8 с BOM** для скриптов с не-ASCII. Файлы `.md` — без BOM.

### 2026-11-12. Правка `.ps1` инструментом `edit` снимает BOM

- Симптом: после правки `get-ipa.ps1` запуск падает с `Missing closing ')' in expression` на
  строке `if ($LASTEXITCODE -ne 0) {`, в тексте ошибки кириллица вида `Р°Р№Р»Р°` — это UTF-8,
  прочитанный как cp866. `edit` переписывает файл без BOM, и PowerShell 5.1 перестаёт
  понимать строки с русским текстом.
- Проверка BOM по всем скриптам:
  `Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { $b=[IO.File]::ReadAllBytes($_.FullName); "$($_.Name) BOM=" + ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) }`
- Лечение (и что делать после каждой правки `.ps1` с кириллицей):
  `$p="...\get-ipa.ps1"; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($true)))`
- Быстрый гейт без запуска:
  `[void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs); $errs.Count`

## 9. Что осталось за человеком

- Ввод пароля Apple ID в Sideloadly (и 2FA), если сессия истекла.
- Съёмка объекта и разрешения камеры/LiDAR на телефоне.
- Решение о платном Apple Developer ($99/год) — снимает 7-дневный лимит и даёт 1 год профиля.
