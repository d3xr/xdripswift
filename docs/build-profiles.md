# Полная версия и локальная подпись

Пошаговая инструкция для нового разработчика, архитектура и тесты — в [технической передаче4246](developer-handoff-4246.md).

В репозитории хранится полный вариант xDrip+: Ottai CN/Global activation, обязательный read-back срока, отдельная active lifetime operation, NFC wake и исправления GS1. Ограничения локального provisioning profile не удаляют реализацию из исходников.

## Полный профиль

По умолчанию `OTTAI_NFC_WAKE_ENABLED=YES`. Debug и Release используют штатные entitlements с NFC TAG. Личная Apple Developer Team в исходниках не задана.

```sh
cp xDripConfigOverride.xcconfig.example xDripConfigOverride.xcconfig
```

Указать собственный Team ID в созданном файле. Для NFC нужен профиль с NFC TAG entitlement. Сеанс NFC и BLE-активация проверяются на реальном устройстве отдельно от компиляции; включённый флаг не заменяет entitlement.

## Локальный Personal Team

```sh
cp docs/signing/PersonalTeam.xcconfig.example xDripConfigOverride.xcconfig
cp docs/signing/PersonalTeam.entitlements.example xDripPersonalTeam.entitlements
```

Указать свой Team ID. Этот профиль выключает только NFC reader, сохраняя весь код BLE activation/read-back и остальные возможности. Спящему CN/Syai понадобится внешнее NFC-пробуждение. Исследованный Global не требует этого шага.

Не заменять уже настроенный локальный override без сохранения его значений. При смене Team могут измениться Bundle ID и App Groups, включая совместимость с Trio.

## Порядок конфигурации

`xDrip/xDrip.xcconfig` → `Version.xcconfig` → optional `VersionOverride.xcconfig` → optional `xDripOverride.xcconfig` → root `xDripConfigOverride.xcconfig`. Root override применяется последним. Значения командной строки Xcode имеют более высокий приоритет.

Живые overrides и `xDripPersonalTeam.entitlements` исключены из Git. В репозитории остаются только переносимые примеры без личного Team ID.

Для локальной сборки: `bash scripts/build-local.sh`. Скрипт не устанавливает приложение на телефон. Его signing/provisioning действия зависят от выбранного локального профиля.

Android keystore не используется: нужен собственный Apple signing certificate/private key в Keychain и provisioning выбранной Team. Перед повторением сборки проверить требования toolchain/ARM64 и совместимость App Groups с Trio в технической передаче.
