# xDrip+ для iOS

Интеграционная сборка **xDrip4iOS 7.2.0 / 4246** с Ottai CN/Global/Syai, Sibionics GS1 CN, AiDex/LinX/LumiFlex и передачей штатной глюкозы в Trio. Это iOS-проект; он не является Android xDrip+ и не использует Android keystore.

Исходная upstream-база: [JohanDegraeve/xdripswift@ba37f261](https://github.com/JohanDegraeve/xdripswift/tree/ba37f261352eedfb7f518c4a38e2266acb0f95e9), 7.2.0 / 4234. В этой базе перечисленных дополнительных семейств нет. Ottai/Syai основан на [PR736](https://github.com/JohanDegraeve/xdripswift/pull/736); AiDex/LinX/LumiFlex — отдельная интеграция из [PR740](https://github.com/JohanDegraeve/xdripswift/pull/740). Остальные upstream-источники CGM и функции приложения сохранены.

Публичная интеграционная ветка — **`custom-build`**. [Как опубликован снимок и что исключено](docs/public-snapshot.md).

## Что добавлено

| Направление | Реализовано | Граница подтверждения |
|---|---|---|
| Ottai CN/Global | Собственная BLE-подготовка нового сенсора, cloud credentials, factory parameters и активация; запрос до 30 дней с обязательным точным read-back | Первая физическая активация этой версией ещё не испытывалась; нужны аккаунт и интернет |
| Активный Ottai | Отдельный ручной запрос общего срока 30 дней от исходного старта, read-back и повторная проверка status 3; без RTC/ACTIVATE/сброса возраста | Подтверждённый параметр не доказывает пересчёт firmware deadline или работу после прежнего срока |
| NFC wake CN/Syai | Ручное пассивное RF-поле ISO14443, без proprietary tag commands и автоматической BLE-активации | Нужна подпись с NFC TAG; readiness/tag detection не подтверждают identity или физический wake |
| Syai | Сохранена прежняя server-assisted активация с серверными frames | Opaque серверный срок не выдаётся за подтверждённые 30 дней |
| Sibionics GS1 CN AA55/V115G | Direct BLE, непрерывный журнал, локальный native-алгоритм, новые final corrections и обычный экспорт в Trio | Проверено чтение уже работавшего GS1; физический cold start не испытывался |
| GS1 после 14 дней | Отдельная диагностика final в карточке устройства до 23 д 19 ч 41 мин от исходного старта | По умолчанию выключена; не поступает в основной график, уведомления или Trio и не перезапускает сенсор |

**В Git хранится полный профиль:** NFC включён, используются штатные TAG entitlements. Личные Team ID, provisioning и ограничения Personal Team остаются в игнорируемом локальном override. Для включения NFC после получения подходящей подписи переписывать реализацию не нужно.

## Документация для разработчика

- [Техническая передача 4246: архитектура, сенсоры, два сценария срока, сборка и проверки](docs/developer-handoff-4246.md).
- [Полный список изменённых файлов](docs/changes-4246.md).
- [Профили собственной подписи: полный и Personal Team](docs/build-profiles.md).
- [Протокол активации Ottai](docs/ottai-activation.md).
- [GS1 Native: использование и пересборка исходников](Vendor/GS1Native/README.md).
- [История подготовки upstream и отдельных PR](docs/upstream/PLAN.md).

## Быстрая сборка со своей подписью

Проверенная среда — Mac Apple Silicon, **Xcode 27.0 / SDK 27.0**, Python3. Готовый GS1 XCFramework содержит ARM64 для iPhone и Simulator; x86_64 Simulator не поставляется. Обычная сборка не требует Kotlin, JVM, CocoaPods или загрузки отдельного native core.

```sh
git clone --branch custom-build https://github.com/d3xr/xdrip-plus.git xdrip-plus
cd xdrip-plus
cp xDripConfigOverride.xcconfig.example xDripConfigOverride.xcconfig
```

Указать собственный `XDRIP_DEVELOPMENT_TEAM` в созданном файле. Настроить доступные этой Team HealthKit, NFC TAG и App Groups для приложения и расширений. Для прямого sharing с Trio нужны совместимые подписи и App Groups; чужая Team не получает доступ к прежнему контейнеру только от совпадения строки идентификатора.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/build-local.sh
```

Скрипт собирает `.app`, проверяет подпись и выводит путь пакета. Он не устанавливает приложение и не запускает сенсор. Для работы в Xcode открыть `xdrip.xcworkspace`, scheme `xdrip`.

Для Personal Team — [отдельный локальный профиль](docs/build-profiles.md#локальный-personal-team). Он отключает только NFC. Спящему CN/Syai тогда требуется внешнее NFC-пробуждение; исследованный Global использует BLE без этого шага.

## Проверки и ограничения

На реализации 4246 выполнены **313 целевых XCTest** без ошибок в подготовленном окружении, включая 43 новых теста. На чистом checkout один тест личного GS1 replay ожидаемо пропускается: его приватные входные данные не входят в репозиторий. Это не результат полного upstream suite. Подробности и воспроизводимые команды — в [технической передаче](docs/developer-handoff-4246.md#проверки).

Simulator, synthetic HTTP и transport seams проверяют программную логику. Они не подтверждают реальный Bluetooth/NFC, новую физическую активацию, точность или продление firmware. Чтение истории, ACK, read-back срока и новые измерения после прежнего deadline — разные уровни подтверждения.

## Происхождение и лицензии

Проект наследует [GPLv3](LICENSE) xDrip4iOS. Атрибуция Ottai/JugglucoNG сохранена в исходниках; для GS1 Native — [NOTICE](Vendor/GS1Native/NOTICE.md), лицензии и source archive. GS1 core — community reverse engineering, не официальный SDK производителя. Общая документация upstream: [xdrip4ios.readthedocs.io](https://xdrip4ios.readthedocs.io/en/latest/).
