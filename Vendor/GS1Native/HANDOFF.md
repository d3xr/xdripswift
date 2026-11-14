# GS1 V115G Native core — передача в интеграцию

Дата: 31.10.2026. Связи: `README.md`, `NOTICE.md`,
`../cgm-driver-research-expanded/gs1-integration/jugglucong/REVIEW.md`.

Собран **GS1Native.xcframework** для iPhone ARM64 и iOS Simulator ARM64:
`build/GS1Native.xcframework`. Это статический framework с Kotlin/Native runtime;
не требует JVM на телефоне. Рабочий xDrip не изменён.

## Что вошло

Pinned GPL3 JugglucoNG `11e6e29db7d9055c8fd2e96261812e16f2095f3d`:
ExactV115GCore, ExactV115GClip и две observation-модели. Алгоритмические выражения
не менялись; механический diff — `evidence/mechanical-port.diff` (53 строки).
V116A сохранён для дальнейшего аудита, но в framework не включён.

Swift API — `GS1V115GEngine(sensorIdentity:factorySensitivity:)`,
`accept(rawMmol:temperatureC:index:)`, `snapshot()`, `restore(snapshot:)`.
Полный работающий пример — `tests/SwiftImportSmoke.swift`.

Только `.correction` + ненулевой `finalMmol` возвращает финальный core-результат.
Промежуточные минуты и abnormal-ветки дают nil. Минутного raw/delta fallback нет.
Finite raw0 продвигает индекс без публикации. После первого принятого индекса
разрешён только следующий; пропуск требует backfill внешним драйвером.

Snapshot envelopev2 проверяет полный source SHA/семейство/compatrevision,
sensorIdentity, sensitivity, lastIndex и CRC32. Restore сначала проверяет отдельный
candidate, поэтому повреждённый файл не меняет активное состояние.

## Что измерено

| Проверка | Результат |
|---|---|
| Публичная CSV, 15 765 минутных входов | 3 153 vendor-oracle совпадения, максимальная ошибка0.0mmol/L |
| Выдача final correction | 3 152 ненулевых результата; исходный0 на index25 отфильтрован |
| JVM original → Native port | 9 155/9 155 checkpoints идентичны: finalFloatbits и hash полного core snapshot |
| Синтетический cold start | 30 000 входов при sensitivity0.8/2.5, включены в differential trace |
| Продолжение после snapshot | 8 290 строк совпали после восстановления перед index7500 |
| Guards | identity/sensitivity mismatch, CRC/truncation, duplicate/gap/NaN, zero→next проверены |
| Swift bridge | iOS typecheck; macOS executable реально вызвал core, snapshot↔Data и98 строк продолжения |
| Framework | iOS ARM64 + Simulator ARM64 успешно скомпилированы и упакованы |

Машиночитаемые результаты: `evidence/validation-summary.json`,
`evidence/differential-result.json`; полный trace — `evidence/replay-{jvm,macos}.log`.
Хеши framework и источников — `evidence/xcframework-manifest.json` и
`evidence/local-source-hashes.json`. Toolchain2.4.21/JDK21 скачан официально и
проверен SHA256, хранится только здесь; manifest — `evidence/toolchain-manifest.json`.

## Что должен обеспечить xDrip-адаптер

1. Подтвердить поддерживаемый GS1 protocol/algorithm family; не направлять GS1EU,
   GS3 или неизвестный encrypted sensor в V115G по названию/цвету коробки.
2. Валидировать BLE кадры, status, checksum, identity, чувствительность и минутный индекс.
3. Воспроизвести непрерывную историю; запуск CSV с index25 не подтверждает полноту
   реального cold start. Допуск первого индекса в core — низкоуровневый контракт.
4. Применить подтверждённый прогрев и lifecycle, дать исходную дату измерения,
   исключить future/stale/duplicate, не превращать history в актуальную точку.
5. Сериализовать вызовы core и сохранить snapshot с привязкой к сенсору.
6. Передавать в CGM/Trio только допущенные адаптером final corrections.

Реальный датчик, активация, BLE reconnect и runtime на iPhone здесь не проверялись.
Набор тестов доказывает программное совпадение с pinned JVM и публичным oracle,
но не клиническую точность и не поддержку каждого GS1.

При переносе сохранять `LICENSE.txt`, `NOTICE.md`, source revision и изменённые
исходники/сборочный рецепт. Никаких покупок, глобальных установок или изменений
помпы не выполнено.
