# S2FM Repair Kit for current Counter-Strike 2

This kit fixes the two regressions that currently make Source 2 Filmmaker hard to
use in Counter-Strike 2:

1. map sunlight/shadows are restored by disabling the new Sparse Shadow Tree
   path for CS2 tools and returning SFM to the classic cascaded-shadow path;
2. a standards-compliant MP4 is assembled from SFM's image sequence and WAV
   output with the FFmpeg bundled in the portable release.

No game DLL is replaced. The lighting change is hash-checked, backed up and fully
reversible.

## Приложение (рекомендуется)

Распакуйте ZIP целиком в обычную папку и запустите `S2FM Repair Manager.exe`.
Не запускайте EXE прямо из архива и не вынимайте его отдельно: рядом нужны папки
`tools`, `templates` и PowerShell-скрипты. Приложение само находит Steam-библиотеку,
установленные карты, создаёт выбранный аддон и следит, не обновила ли Steam исходный
VPK. Если Windows SmartScreen показывает предупреждение для неподписанного
community-приложения, сверяйте SHA-256 архива с файлом `.sha256` рядом с релизом.
Папки из `game\csgo_addons` и `content\csgo_addons` автоматически появляются в
редактируемом списке **Аддон**. Можно выбрать существующий аддон либо вписать новое
корректное имя — при первом монтаже менеджер создаст его автоматически.

Требования к компьютеру:

- 64-битная Windows 10 22H2 или Windows 11;
- установленная в Steam Counter-Strike 2 вместе с **Counter-Strike 2 Workshop Tools**;
- достаточно свободного места для временной копии community-карты, если библиотека
  Steam находится на файловой системе без NTFS-hardlink (на NTFS копий не создаётся);
- интернет после скачивания ZIP не требуется.

В релиз уже входят переносимые .NET runtime, ValveResourceFormat CLI и FFmpeg.
Устанавливать PowerShell, .NET, Python, CapCut или кодеки отдельно не нужно.

Исходный код и инструкция воспроизводимой сборки находятся в
[`SOURCE_BUILD.md`](SOURCE_BUILD.md). Git-репозиторий намеренно не содержит
собранные EXE, ZIP-релизы и сторонние бинарники крупнее лимита GitHub; оба внутренних
патчера собираются из C#-исходников автоматически.

1. Сохраните работу и закройте CS2/SFM.
2. В поле **Сессия** введите новое имя, например `session_test`, либо выберите
   существующую сессию из списка.
3. Выберите одну карту.
4. Нажмите **Смонтировать и запустить**.

Изменение `gameinfo.gi`, необходимое для света SFM, теперь действует только во
время работы SFM. Менеджер включает его непосредственно перед запуском, а скрытый
cleanup-helper после закрытия SFM возвращает исходный файл с проверкой SHA-256.
Обычная кнопка **Смонтировать карты** конфигурацию клиента не меняет. Если старый
релиз оставил патч активным, новый менеджер автоматически восстановит официальный
клиент при запуске или по кнопке **Обновить**, когда CS2/SFM закрыт. Не запускайте
обычный CS2 параллельно с SFM: пока в заголовке горит красный статус SFM-патча,
официальные серверы могут отклонять подключение.

Для нового имени менеджер создаст бинарную DMX-сессию, привяжет выбранную карту,
поставит начальную камеру около первой игровой точки спавна и передаст файл через
`-sfm_loadsession`. Поэтому SFM открывается сразу в нужной сессии и карте, минуя
стартовые диалоги игры. Повторный запуск с тем же именем открывает существующую
сессию и никогда её не перезаписывает. Выбранная в таблице карта при этом
игнорируется: существующий DMX открывается с сохранённой в нём картой, камерой,
шотами и анимацией. Чтобы создать отдельную сессию для другой карты, введите новое
уникальное имя.

Для уже смонтированной карты достаточно выбрать сессию и нажать **Запустить SFM**.
После обновления карты состояние изменится на **Нужно обновить** — повторное нажатие
**Смонтировать и запустить** безопасно пересоберёт её патч. Оригинальные VPK игры
приложение не изменяет; ручное удаление патча доступно через
`Uninstall-S2FMMapLightFix.ps1`.

Карты текущей ротации, чьи материалы находятся в `game\csgo_community_addons`,
поддерживаются автоматически. При монтаже установщик извлекает из community-пакета
только связанные VPK карты или скайбокса, которые нужно исправить. При запуске
лаунчер добавляет выбранный split-VPK во временно управляемый `Game` search path,
поэтому материалы, модели и звуки доступны ещё до загрузки SFM-сессии. Tools-режиму
также создаются временные зеркала VPK под `content\csgo_community_addons` и
`src\shaders\csgo_community_addons`: это NTFS hardlink-файлы, а не вторые копии
данных. При переходе на другую карту запись заменяется, а после закрытия SFM скрытый
cleanup-helper удаляет search path и оба зеркала. Гигабайты ресурсов не копируются.

Карты, на которые пользователь подписан в мастерской Steam, также обнаруживаются
автоматически в `steamapps\workshop\content\730`. В списке показываются название из
`publish_data.txt`, внутреннее имя карты и метка **Workshop**; поиск работает по всем
трём полям, включая Workshop ID. При монтаже менеджер извлекает вложенный
`maps/<имя>.vpk`, исправляет свет и подключает весь многотомный пакет ресурсов через
управляемые hardlink-зеркала. Файлы в папке мастерской не изменяются. Обновление
подписки переводит карту в состояние **Требует обновления**, после чего её можно
пересобрать обычной кнопкой.

Для диагностики комплекта можно запустить:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-S2FMRelease.ps1
```

Проверка самой установки CS2:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-S2FMRelease.ps1 `
  -Cs2Root "D:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive"
```

## Командная строка

Close CS2/SFM, then run PowerShell in this folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-S2FMPatch.ps1
.\Install-S2FMMapLightFix.ps1 -Map de_overpass
.\Install-S2FMMapLightFix.ps1 -Map aim_map -WorkshopId 3084291314
.\Start-S2FMPatched.ps1
```

По умолчанию используется аддон `sfm_repaired`. Путь CS2 определяется через реестр
Steam и `libraryfolders.vdf`; при необходимости его можно выбрать кнопкой `…`.

Current SFM does not instantiate a baked `light_environment` sun. The map-light
installer extracts the embedded entity lump and builds a complete addon-local copy
of the map VPK. Ordinary maps use stationary sunlight (`directlight=3`). For maps
with a legacy `skybox_reference`, the referenced 3D skybox is a separate VPK with
its own baked `light_environment`. The installer resolves those references and
patches the main map and every referenced skybox to the same fully dynamic mode
(`directlight=2`). The original CS2 VPKs are not modified. Every installed copy is
hash-tracked and can be removed from the addon independently.

`Repair-S2FMSessionLight.ps1` remains available for scenes that need a custom
directional light rather than the map's own sun. Save and close the session, then
run:

```powershell
.\Repair-S2FMSessionLight.ps1 `
  -Session "D:\path\to\elements\sessions\shot.dmx" `
  -LightName dirlight1 -Intensity 2.8 -Color 248,212,171
```

The script updates both the light and its animation-control graph, then verifies
a binary DMX round-trip. It places the original session in
`game\csgo\s2fm_repair_backup\session_lights` before replacement.

In SFM, export an **Image Sequence** and WAV. Then convert it:

```powershell
.\Convert-S2FMExportToMp4.ps1 -Frames "D:\renders\shot\000000000.png" -Audio "D:\renders\shot\shot.wav"
```

You can also pass the folder containing one numbered sequence:

```powershell
.\Convert-S2FMExportToMp4.ps1 -Frames "D:\renders\shot" -FrameRate 60
```

The script detects the numbered sequence, checks for missing frames, finds
FFmpeg, chooses the best available H.264 encoder, adds AAC audio and writes a
fast-start MP4 next to the source files.

## Rollback

Close CS2/SFM and run:

```powershell
.\Uninstall-S2FMPatch.ps1
.\Uninstall-S2FMMapLightFix.ps1 -Map de_overpass
```

Steam updates can replace `gameinfo.gi`. If that happens, simply run the installer
again. The installer never overwrites an unknown edit or backup silently.

See [TECHNICAL_ANALYSIS.md](TECHNICAL_ANALYSIS.md) for the investigation and the
reason DLL replacement is deliberately not used.
