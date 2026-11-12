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
| **Стоит на телефоне** | **0.11.0 (build 11)** — сильно старше `main` (0.15.0) |
| Профиль | выставлен 29.10.2026 16:49, TTL 7 дней → **истёк 05.11.2026 16:49 MSK** |

Следствие: приложение на телефоне **сейчас не запускается** — iOS не даёт стартовать процессу
с истёкшим профилем. Нужна переподпись свежим профилем (Sideloadly), и лучше сразу 0.15.0.

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

Проверено 12.11.2026: `ScanLab-unsigned.ipa` = **0.15.0 (build 16)**, `run=34`, commit `0dd6726`,
sha256 `967bda9016e28b1b7bfd8d07d903a6f4cfae1e3e97771e8aee85246525aa0201`.
Внутри IPA **нет** `embedded.mobileprovision` — подпись добавляет Sideloadly.

Артефакты GitHub (`pipelines.githubusercontent.com`) на этой сети могут не открываться —
поэтому IPA берём **из ветки `builds` через git**, а не со страницы артефактов.

## 5. Установка на телефон

1. `.\get-ipa.ps1` — IPA в корне репозитория.
2. Открыть `C:\Users\lenov\AppData\Local\Sideloadly\sideloadly.exe`.
3. Перетащить `ScanLab-unsigned.ipa` в окно, убедиться, что выбран iPhone (UDID `00008130-…`).
4. Рядом с Apple ID должно стоять `nabarnov@yandex.ru`; поле Bundle ID — `com.scanlab.app`
   (Sideloadly сам добавит хвост `3CB3DRNXR2`).
5. Нажать **Start** и дождаться `Done`. Пароль/2FA — только человек.
6. Проверить: `.\tools\ios.ps1 status` → версия должна совпасть с `BUILD.txt`.

Ограничения свободного Apple ID: профиль 7 дней, 3 приложения, 10 новых App ID в неделю.
Повторная установка с тем же bundle id слот не тратит.

## 6. Логи и запуск

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 launch        # DVT-запуск
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 logs -Seconds 20
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\ios.ps1 pull          # Documents/Scans
```

Проверено 12.11.2026: `syslog live` отдаёт ~600 строк в секунду (за 8 с — 4813 строк, файл в
`logs/`), фильтр по `ScanLab` — 0 совпадений, потому что приложение не запускается (профиль истёк).

Если `dvt launch` отвечает
`DTXNsError: com.apple.dt.deviceprocesscontrolservice (code 2, … 'Request to launch … failed.')` —
почти всегда это истёкший/битый профиль либо приложение удалено. Смотреть `status`.

## 7. Тесты без телефона

```powershell
.\tools\tests\...                            # Python: калибровка, масштаб, меш
& $py -m pytest tools\tests -q               # если стоит pytest
```

Swift-логика (`Core/ScanCoach.swift` и т.п.) локально не собирается — на этом стенде нет
Swift-тулчейна. Её компиляцию и проверки подтверждает только CI-прогон.

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
- Лечение: `git reset -- ScanLab-unsigned.ipa` перед коммитом; в `main` IPA не попадает.

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

## 9. Что осталось за человеком

- Ввод пароля Apple ID в Sideloadly (и 2FA), если сессия истекла.
- Съёмка объекта и разрешения камеры/LiDAR на телефоне.
- Решение о платном Apple Developer ($99/год) — снимает 7-дневный лимит и даёт 1 год профиля.
