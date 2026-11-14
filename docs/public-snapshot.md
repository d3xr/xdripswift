# Публичная сборка custom-build

Версия 7.2.0 / 4246, 14.11.2026. Эта ветка содержит актуальную интеграцию Ottai CN/Global/Syai, GS1 CN и AiDex/LinX/LumiFlex одним коммитом поверх публичной базы [ba37f261](https://github.com/JohanDegraeve/xdripswift/tree/ba37f261352eedfb7f518c4a38e2266acb0f95e9). Приватная история commits не переносится. Ветки upstream и отдельных исправлений сохраняются отдельно.

Связи: [README](../README.md), [архитектура и сборка](developer-handoff-4246.md), [файлы последнего этапа 4246](changes-4246.md), [собственная подпись](build-profiles.md), [GS1 provenance и лицензии](../Vendor/GS1Native/NOTICE.md).

## Что входит

Runtime, тесты, схемы миграции Core Data, assets и поставляемый GS1 Native совпадают с проверенной реализацией 4246. Сохранены XCFramework для ARM64 device/Simulator, соответствующие исходники, recipe, SHA-256 и лицензии. Модели со словом `personal` — схемы совместимости; пользовательских баз в снимке нет.

В проверенных static archives сохранена отладочная информация с путями исходников на машине сборки. Это метаданные native build, не профиль подписи или credentials; бинарники не модифицировались при экспорте.

Из экспортированного дерева исключены архивная личная validation receipt, настройки `xcuserdata` и скомпилированный `.pch`. Личные signing overrides, provisioning, сертификаты, private replay inputs и локальные outputs не переносились. В Git остаются только общие templates: разработчик задаёт собственную Team в ignored override. NFC в общем профиле включён.

Документация переведена на `custom-build`; ссылки на недоступные приватные commits убраны. GitHub build workflow в этой ветке оставлен ручным: автоматические sync/release по расписанию отключены. Ручной Fastlane release — отдельный путь, требующий собственных GitHub/Apple secrets и явно выбранного запуска; он не нужен для локальной сборки.

## Сборка

```sh
git clone --branch custom-build https://github.com/d3xr/xdrip-plus.git xdrip-plus
cd xdrip-plus
cp xDripConfigOverride.xcconfig.example xDripConfigOverride.xcconfig
```

Указать собственную Team, настроить capabilities и выполнить команды из [технической передачи](developer-handoff-4246.md#5-сборка-с-собственными-ключами). Канонический публичный репозиторий — `d3xr/xdrip-plus`. Прежний URL `d3xr/xdripswift` перенаправляет на него. Ветка `custom-build` выбрана основной. Для clone нужен именно `--branch custom-build`: `master/develop` сохраняют прежнее содержимое.

## Границы проверки

Снимок переносит проверенный код; наличие кода не означает испытание нового физического сенсора. Срок active Ottai требует отдельного аппаратного подтверждения после прежнего deadline. GS1 post14 остаётся отдельной диагностикой без обычного BG/Trio. Текущий сенсор при публикации не используется.

313 целевых XCTest ранее прошли в подготовленной среде. Чистый checkout ожидаемо пропускает один private GS1 replay case без личных входных данных. Команды для самостоятельной проверки находятся в технической передаче; этот результат не равен всему upstream suite.
