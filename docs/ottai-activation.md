# Ottai: активация и срок

Сравнение с GS1, два сценария срока и сборка со своей подписью — в [технической передаче4246](developer-handoff-4246.md).

Реализация основана на JugglucoNG `91fed63ffb83b5b002186a8574b4af696c3839f9`; происхождение отдельных частей закреплено в source comments. Настройка подписи описана в [build profiles](build-profiles.md).

## Новый сенсор CN/Global

`Start / activate sensor` получает материалы из аккаунта производителя и выполняет BLE-подготовку без обязательной активации родным приложением. Fresh bootstrap проходит server auth, получение ключей с полной live firmware revision, собственную локальную сессию и заводские параметры. Незавершённая preparation сохраняется и не считается завершённой по одному факту получения ключей.

Запрашивается общий срок до30дней. При явном ATT-отказе возможен меньший кандидат. После записи необходим точный read-back; один ACK не разрешает продолжение активации. Неподтверждённый срок, ошибка, timeout или отсутствующая характеристика останавливают активацию.

Спящий CN/Syai требует отдельного NFC wake. `Wake sensor with NFC` использует пассивное RF-поле ISO14443 без proprietary tag commands и не вызывает BLE ACTIVATE. Обнаружение тега не подтверждает identity или успешный wake; затем нужно проверить Bluetooth и отдельно запустить activation. Для этого reader нужен NFC-enabled signing profile. Прежний Syai server-assisted путь сохранён; его opaque server-defined срок не выдаётся за подтверждённые30дней.

## Активный сенсор

`Request 30-day lifetime` запрашивает30дней от исходного старта. Это отдельный flow: fresh status3 → baseline duration → одна duration write → ACK → exact read-back → fresh status3. RTC, retain, ACTIVATE, bind и изменение original start/dataNo/history в нём отсутствуют.

Прерванная операция сохраняет intent. Следующий ручной запрос читает результат без автоматического повторения write. Существующий подтверждённый срок не заменяется одним ACK.

Подтверждение параметра не доказывает, что firmware пересчитала текущий deadline или продолжит новые измерения после прежнего срока. Аппаратная поддержка active rewrite, новая физическая activation и NFC wake этой версии ещё требуют отдельных испытаний; software tests не заменяют их.

## Проверка кода

313 XCTest проверены на версии4246, включая43 новых теста: actual runtime continuations через transport seams, encrypted read-back, Fresh/cached CN, Global, Syai compatibility, interruption/reconciliation, NFC lifecycle и регрессии GS1. Синтетические HTTP/NFC/BLE порты не являются испытанием на сенсоре. Приватные replay inputs, логи устройств и медицинские БД в публикацию не входят.
