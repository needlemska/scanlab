# Стенд для iOS-разработки без Mac

Этот файл — про то, где мы работаем, что на стенде уже есть и что нельзя сделать
без прав администратора. Проверка одной командой:

```powershell
powershell -File tools\devstack.ps1
```

## Что проверено на этом стенде (01.11.2026)

| Компонент | Состояние | Зачем |
|---|---|---|
| Windows 11 Pro, build 26300 | есть | — |
| git 2.53 | есть | репозиторий |
| gh 2.95 | есть, **вход не выполнен** | прогоны CI, `gh auth login` |
| Python 3.14.4 + numpy 2.4.4 | есть | `pc/` и тесты |
| pymobiledevice3 11.49.1 | есть | логи и файлы телефона по USB |
| iTunes / Apple Mobile Device Service | есть, служба запущена | связь с телефоном |
| MSVC (VS Build Tools, `H:\vsc`) | есть | линковка для Swift |
| 7-Zip 26.02 | есть | распаковка установщиков |
| VS Code | есть, расширения: Python | редактор |

Проверка ПК-части проходит прямо здесь: `python tools\tests\test_calibration.py` —
22 проверки, около секунды (масштаб по позам ARKit, по глубине LiDAR, поворотный стол,
разборы `images.txt` и `shots.json`).

## Чего на стенде нет и почему

**Xcode и Simulator.** Существуют только для macOS. Никакая эмуляция это не
заменяет: сборка под iOS — это `xcodebuild` с iPhoneOS SDK, а он лицензирован
только для Apple-железа. Поэтому сборка живёт в CI на `macos-latest`.

**Swift-тулчейн.** На прошлом стенде он стоял (`Swift 6.4.1`), здесь — нет.
Ставится только с правами администратора:

```powershell
winget install --id Swift.Toolchain -e --accept-package-agreements --accept-source-agreements
```

**Sideloadly.** Установщик и распакованная портативная копия запускаются с кодом 5
(отказ доступа): программа ставит свой драйвер устройства, для этого нужен админ.
Обычная установка:

```powershell
winget install --id Sideloadly -e
```

После этого путь такой же, как раньше: перетащить IPA в окно → Start.

## Что работает без прав администратора

1. **Репозиторий и код.** Клон, ветки, диффы — всё как обычно.
2. **ПК-пайплайн.** `python pc\photogrammetry.py`, `pc\scale_from_poses.py`,
   `pc\scale_from_depth.py`, `pc\turn_table_check.py`, `pc\measure.py` — им нужен
   только numpy (для `.ply` ещё open3d, ставится в user-scope).
3. **Тесты ПК-части.** `python tools\tests\test_calibration.py` — те же проверки,
   что гоняет CI.
4. **Телефон по USB.** `pymobiledevice3` видит устройство без прав администратора:

   ```powershell
   python -m pymobiledevice3 usbmux list          # какие телефоны подключены
   python -m pymobiledevice3 syslog live         # консоль устройства в реальном времени
   python -m pymobiledevice3 apps list <UDID>    # что установлено
   python -m pymobiledevice3 afc pull <путь> .   # забрать папку со сканами
   ```

5. **Сборка и проверки в CI.** Каждый пуш собирает IPA на macOS-раннере и прогоняет
   Swift-тесты логики и Python-тесты (workflow `check`).

## Что делает CI (и почему локальный Swift не обязателен)

| Workflow | Где | Что |
|---|---|---|
| `build` | macOS | XcodeGen → `xcodebuild` → IPA в ветку `builds` |
| `check` | macOS + ubuntu | Swift-проверки логики (`swiftc` + запуск) и `tools/tests/test_calibration.py` |
| `convert-model` | ubuntu | конвертация модели в Core ML (вручную, по кнопке) |

Логика проверяется в CI тем же файлом `tools\logic\main.swift`, что и локально на
стенде со Swift, — расхождений нет.

## Порядок действий, чтобы стенд стал полным

1. Войти в GitHub (нужно для `gh run`/`gh run watch` и пуша):

   ```powershell
   gh auth login
   ```

2. Поставить Swift (нужен админ; если ставится через `winget`, попросит UAC):

   ```powershell
   winget install --id Swift.Toolchain -e
   ```

   После установки: `powershell -File tools\logic-test.ps1` — 34 проверки логики
   локально, без CI.

3. Поставить Sideloadly (нужен админ): `winget install --id Sideloadly -e`.

До шага 2 логика проверяется в CI, до шага 3 приложение на телефон не поставить.

## Полезное

- `install.ps1 -Check` — проверить, что установлено на телефоне (подпись, срок).
- `get-ipa.ps1` — забрать свежий IPA из ветки `builds` без входа в веб-интерфейс.
- `TESTING.md` — полевой тест; без него все цифры точности остаются синтетикой.
