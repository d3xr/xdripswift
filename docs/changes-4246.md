# Файлы реализации 4246

Историческая инвентаризация последнего этапа реализации 4246 относительно предыдущей внутренней сборки: 56 операций, затрагивающих 57 путей (переименование считается одной операцией), из них 34 текстовые операции и 22 PNG. Это не полный diff публичной `custom-build` от upstream: ранние интеграции входят в единый публичный снимок. Приватная история Git не переносилась; [состав снимка](public-snapshot.md).

Связи: [архитектура и сборка](developer-handoff-4246.md), [README](../README.md).

## Конфигурация, документация и упаковка

| Файл | Изменение и ответственность |
|---|---|
| `.gitignore` | Игнорирование живых локальных overrides и Personal Team entitlements |
| `README.md` | В реализации добавлена навигация по профилям/активации; текущая передача расширяет обзор проекта |
| `Vendor/GS1Native/WireProtocol/README.md` | Команды wire-проверки и границы протокола |
| `docs/build-profiles.md` | Полный NFC/TAG профиль и локальный Personal Team |
| `docs/ottai-activation.md` | Fresh activation, active lifetime и пределы доказательств |
| `xDripPersonalTeam.entitlements → docs/signing/PersonalTeam.entitlements.example` | Живой локальный профиль убран из tracked root и сохранён как переносимый пример |
| `docs/signing/PersonalTeam.xcconfig.example` | Пример локальной подписи с NFC NO |
| `docs/upstream/PLAN.md` | Актуальные переносимые инструкции и upstream-навигация |
| `scripts/build-local.sh` | Изолированные outputs, фактический путь `.app` из build settings, проверка подписи без установки |
| `xDrip/Supporting Files/Info.plist` | `OttaiNFCWakeEnabled` и описание использования NFC |
| `xDrip/Version.xcconfig` | Общая версия 4246 |
| `xDrip/xDrip.xcconfig` | Полный профиль NFC YES/TAG, имя xDrip+, отсутствие личной Team |
| `xDripConfigOverride.xcconfig` — удалён из Git | Реальная локальная подпись больше не публикуется как общий default |
| `xDripConfigOverride.xcconfig.example` | Общий пример выбора собственной Team |
| `xdrip.xcodeproj/project.pbxproj` | NFC source membership и build paths |

## Runtime и UI

| Файл | Ответственность |
|---|---|
| `xDrip/BluetoothTransmitter/CGM/Generic/CGMTransmitterDelegate.swift` | Инвалидация отложенной доставки и наблюдение исходной сессии |
| `xDrip/BluetoothTransmitter/CGM/Ottai/CGMOttaiTransmitter.swift` | BLE state machine, Fresh preparation, mandatory read-back, active-only операция, recovery |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiCloudClient.swift` | Fresh validation/bind/GET reconciliation и безопасное сохранение материалов |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiConstants.swift` | Кандидаты срока не превышают 30 дней |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiGlobalContract.swift` | Полная live revision и точное сопоставление firmware/build/variant |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiNFCWake.swift` — новый | Пассивная RF-сессия; signing/owner/foreground/lifecycle guards; без BLE/cloud действий |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiRegionalTransport.swift` | Региональная native encrypted-маршрутизация |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiRegistry.swift` | Durable preparation/lifetime intents, physical start, evidence и статусы |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiSecureHTTP.swift` | Разрешённый CN secure host; запрет redirects |
| `xDrip/BluetoothTransmitter/CGM/Ottai/Core/OttaiV3BootstrapPolicy.swift` | Factory frames, activation gates, lifetime transaction/codecs и модели checkpoints |
| `xDrip/BluetoothTransmitter/CGM/Sibionics/CGMSibionicsTransmitter.swift` | GS1 BLE/reconnect, ordinary publication и отдельный diagnostic store |
| `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1Session.swift` | Непрерывный журнал и проверка его timestamps, native replay, start,14 дней и post14-диагностика |
| `xDrip/Managers/Application/RootApplicationCoordinator.swift` | Согласование исходной GS1-сессии без потери старой истории/калибровок |
| `xDrip/SwiftUIViews/BluetoothPeripherals/BluetoothPeripheralDetailState.swift` | Ottai activation/lifetime/NFC UI и отдельная GS1 post14-карточка |

`GS1Protocol.swift`, engine bridge, `LoopManager` и миграционные модели также участвуют в архитектуре, но не изменены именно этим commit. `GS1Journal` находится внутри изменённого `GS1Session.swift`. Ранняя интеграция и committed `Vendor/GS1Native` сохраняются; native binary/source archive и лицензии не заменялись.

## Тесты

| Файл | Что проверяет изменение |
|---|---|
| `xDrip Tests/GS1IntegrationTests.swift` | История/native state, freshness, post14 и export boundaries; optional private replay loader без публикации входных данных |
| `xDrip Tests/OttaiGlobalLoginTests.swift` | Fresh HTTP/bind, account identity, lost bind response и восстановление |
| `xDrip Tests/OttaiRegionalTransportTests.swift` | Региональная маршрутизация и CN encrypted headers |
| `xDrip Tests/OttaiServerActivationTests.swift` | Срок/codec, activation policies, durable state и NFC lifecycle |
| `xDrip Tests/OttaiStartupBackfillTests.swift` | Реальные continuations через transport seams: read-back, active operation, Fresh/cached CN, Global и legacy Syai |

## Иконки: 22 PNG

Оформление xDrip+ для основного приложения, preview и Watch. Оно не меняет протокол CGM.

```text
xDrip Watch App/Assets.xcassets/AppIcon.appiconset/Icon-1025.png
xDrip Watch Complication/Assets.xcassets/AppIcon.appiconset/Icon-1025.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1025.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-121.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-122.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-153.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-168.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-181.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-21.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-30.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-41.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-42.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-43.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-59.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-61.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-62.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-77.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-81.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-82.png
xDrip/Resources/Assets.xcassets/AppIcon.appiconset/Icon-89.png
xDrip/Resources/Assets.xcassets/AppIconPreview.imageset/AppIconPreview@2x.png
xDrip/Resources/Assets.xcassets/AppIconPreview.imageset/AppIconPreview@3x.png
```

## Что меняет документирующий PR

- Расширяет `README.md` и GitHub About описанием текущего проекта.
- Добавляет этот список и `docs/developer-handoff-4246.md`.
- Исправляет пути пересборки в `Vendor/GS1Native/README.md`: recipe находится внутри source archive.
- Добавляет навигацию в `docs/build-profiles.md`, `docs/ottai-activation.md` и `docs/upstream/PLAN.md`.

Swift/C/Kotlin runtime, signing profiles, данные сенсоров и native binary этот PR не изменяет.
