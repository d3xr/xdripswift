# GS1 V1.1.5G: изолированный Kotlin/Native core

Это вычислительное ядро GS1 CN; BLE, жизненный цикл и экспорт реализованы отдельно
в Swift-драйвере приложения. См. [техническую передачу](../../docs/developer-handoff-4246.md)
и [исторический HANDOFF](HANDOFF.md). Обычная сборка приложения использует уже
поставляемый `GS1Native.xcframework`, не требует JVM/Kotlin и не запускает сенсор.

## Граница реализации

- Pinned JugglucoNG `11e6e29db7d9055c8fd2e96261812e16f2095f3d`.
- Только ExactV115GCore + ExactV115GClip. V116A сохранён для аудита, в бинарник не входит.
- Арифметика исходников сохранена; изменения только в Java/common совместимости.
- Нет BLE, активации, QR, выбора версии протокола, часов датчика и передачи в Trio.
- Каждая минутная точка поступает в core. Публикуется только финальная correction
  на пятиминутном шаге; raw fallback и минутный delta-carry отсутствуют.
- NO_CORRECTION включает как промежуточную минуту, так и отклонённую core точку.
- Порядок вызовов должен быть последовательным. Первый индекс задаёт вызывающий
  код; затем принимается только `lastIndex + 1`. Полноту первоначальной истории
  и прогрев обеспечивает внешний драйвер.
- Snapshot содержит identity, sensitivity, алгоритм/версию envelope, последний
  индекс и CRC32; неудачный restore сохраняет текущий core без изменений.
  CRC предназначен для повреждения файла, а не аутентификации.
- Finite raw0 проходит в неизменённый core и продвигает индекс без публикации.
- Envelopev2 содержит полный pinned source SHA и compatrevision.

## Swift-facing API

`GS1V115GEngine(sensorIdentity:factorySensitivity:)` создаёт отдельный core.
`accept(rawMmol:temperatureC:index:)` возвращает GS1CoreResult с `status`,
`sensorIndex`, `finalMmol`. Только `CORRECTION` содержит пригодный по контракту
core финальный результат; это ещё не разрешение публикации в CGM.

`snapshot()` / `restore(snapshot:)` используют KotlinByteArray. Перенос snapshot
между разными identity или sensitivity отклоняется. `lastAcceptedIndex` позволяет
внешнему драйверу продолжить backfill. Методы не предназначены для конкурентных
вызовов; адаптер должен работать на одной последовательной очереди.

## Проверка без пользовательских данных

Публичный `sibionics_exact_v115g_replay.csv` содержит 15 765 строк, index25…15789.
Upstream тест сравнивает **vendor_mmol, четвёртый столбец**, только на index%5==0:
3 153 ожидаемых результата. Столбец exact_mmol не является используемым oracle.
Replay начинается с25; полный cold start index1…24 этой выборкой не покрыт.

`tests/Replay.kt` внутри source archive проверяет:

1. Каждый vendor oracle с исходным допуском0.0001mmol/L.
2. Нулевые промежуточные результаты, отсутствие raw fallback.
3. Восстановление core и façade перед index7500, одинаковое продолжение.
4. Дубликаты, gaps, NaN, несовпадающий sensor/sensitivity, повреждённый checkpoint.
5. JVM vs Native: финальные Float bit patterns и hash полного core snapshot на
   каждом correction; любое отличие сохраняется для разбора.

Оригинальные JVM core/clip для сравнения берутся из `upstream/` исходного архива,
а не из порта.
Это проверка программного совпадения, не клиническая валидация и не проверка
реального сенсора или нового зашифрованного протокола.

## Локальная сборка

Для обычного xDrip build пересборка этого модуля не нужна. Готовый XCFramework
содержит статические device ARM64 и Simulator ARM64 archives; x86_64 Simulator
не поставляется.

### Portable rebuild helper

`rebuild.py` is retained from the earlier public CGM branch (`63dc4a9`). It builds
the current `Source/*.kt` with pinned Kotlin/Native 2.4.21 and JDK 21.0.13+9,
verifies toolchain download hashes, uses relative source paths and checks the
result for absolute build paths. It refuses to overwrite an existing output.

```sh
python3 Vendor/GS1Native/rebuild.py --help
python3 Vendor/GS1Native/rebuild.py --output Vendor/GS1Native/build/portable/GS1Native.xcframework
python3 -m unittest discover -s Vendor/GS1Native/Tests -p 'test_rebuild.py'
```

This helper downloads toolchains only when explicitly run without existing pinned
installations. It does not sign, install or connect to a sensor. The supplied
frameworks were retained unchanged during the 7.2.1 sync; they were not rebuilt
with this helper. A replacement still requires native parity checks and provenance
updates. The original source-archive recipe below remains available for audit.

Для пересборки сначала проверить и распаковать committed source-only archive.
Следующие команды запускаются из корня репозитория:

```sh
cd Vendor/GS1Native
shasum -a 256 -c GS1Native-V115G-11e6e29-source.zip.sha256
XDRIP_GS1_SOURCE_DIR="$(mktemp -d)"
unzip -q GS1Native-V115G-11e6e29-source.zip -d "$XDRIP_GS1_SOURCE_DIR"
cd "$XDRIP_GS1_SOURCE_DIR/gs1-native-core"
cat REBUILD.md
```

`build.py`, bootstrap, replay machinery и `evidence/` находятся **внутри архива**,
не в корне `Vendor/GS1Native`. Из распакованного `gs1-native-core`:

```sh
python3 bootstrap_toolchain.py
python3 build.py jvm
python3 build.py mac
python3 build.py compare
python3 build.py ios
python3 build.py iossim
```

Bootstrap получает pinned Kotlin/Native2.4.21 и JDK21.0.13+9, проверяет SHA-256
и сохраняет toolchain локально в распакованном каталоге. Он не меняет системную
Java или shell profile. Для нестандартного расположения Xcode адаптировать
`DEVELOPER_DIR` в recipe. Исходная сборка использовала SDK27.0.

Логи/сравнения находятся в `evidence/` распакованного архива, frameworks —
`build/iosArm64/GS1Native.framework` и `build/iosSimulatorArm64/GS1Native.framework`.
Команда `xcodebuild -create-xcframework` приведена в `REBUILD.md`; её output должен
быть новым каталогом. Заменять vendor artifact только после parity checks и с
сохранением NOTICE/source manifest. Битовая идентичность всего framework при
другом Apple SDK не заявляется.

Документация компилятора:
https://kotlinlang.org/docs/apple-framework.html

Происхождение и лицензия: [NOTICE.md](NOTICE.md), `evidence/source-manifest.json`
в исходном архиве.
