# Supermicro SEL ECC — Zabbix шаблон + PowerShell обёртка

Мониторинг ошибок памяти ECC, ЦП и прочих аппаратных сбоев по журналу SEL
на серверах Supermicro через Zabbix agent (passive), утилита `IPMICFG-Win.exe`.
Версия Zabbix **6.0 LTS**, ОС **Windows Server 2012 и выше** (PowerShell 3.0+).

## Состав

| Файл | Назначение |
|---|---|
| `supermicro_sel.ps1` | Обёртка: запускает `IPMICFG-Win.exe -sel list -d 1`, парсит оба формата вывода, классифицирует ошибки |
| `IPMICFG-Win.exe` | Утилита Supermicro для доступа к журналу SEL |
| `pmdll.dll` | Бибилиотека парсинга журнала SEL для IPMICFG |
| `Supermicro_IPMI_SEL.yaml` | Шаблон Zabbix 6.0 (уже импортирован) |
| этот README | Развёртывание, настройка |

## Развёртывание

1. Положите файлы `IPMICFG-Win.exe` `pmdll.dll` `supermicro_sel.ps1`  в папку Scripts агента (например
   `C:\Windows\zabbix-agent\scripts\IPMICFG-Win.exe`). При необходимости поправьте `$IPMICFG` в `.ps1`.
2. Добавьте в `zabbix_agentd.conf` (пути поправьте под свою раскладку):

```ini
UserParameter=supermicro.sel.discovery,powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\zabbix-agent\scripts\supermicro_sel.ps1" -Mode discover
UserParameter=supermicro.sel.summary,powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\zabbix-agent\scripts\supermicro_sel.ps1" -Mode summary
UserParameter=supermicro.sel.raw,powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\zabbix-agent\scripts\supermicro_sel.ps1" -Mode raw
UserParameter=supermicro.sel.status,powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\zabbix-agent\scripts\supermicro_sel.ps1" -Mode status
UserParameter=supermicro.sel.count[*],powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Windows\zabbix-agent\scripts\supermicro_sel.ps1" -Mode count -Type "$1" -Location "$2"
```

4. Перезапустите Zabbix agent. **Агент должен работать с правами администратора**
   (LocalSystem или админ-аккаунт) — иначе IPMICFG не получит доступ к BMC по KCS.
5. Добавьте шаблон `d5_Мониторинг IPMI Supermicro` в Zabbix, привяжите к хосту.

Проверка вручную:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\zabbix-agent\supermicro_sel.ps1 -Mode raw
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\zabbix-agent\supermicro_sel.ps1 -Mode discover

## Как это работает

1. Раз в час Zabbix agent вызывает скрипт через UserParameter.
2. Скрипт выполняет `IPMICFG-Win.exe -sel list -d 1` (события за последние **1 день**,
   скользящее окно — не календарный «сегодня»).
3. Парсер понимает оба формата (реальные раскладки, не «из документации»):
   - **Формат 1 (двухстрочный pipe, старые BMC):** заголовок `468 | 2026/08/25 11:32:52 | Memory`
     и отдельная строка `    | Assertion:Correctable ECC@DIMMD1(CPU1)`.
   - **Формат 2 (блок, новые BMC):** `Event:119 Time:… SensorType:BIOS` + `| Msg = Memory Error, … (P1-DIMMB1) - Assertion`,
     события разделены строками `----`.
4. Отбираются только аппаратные ошибки (не информационные/OK/deassertion).
5. Низкоуровневое обнаружение (LLD) создаёт **отдельный триггер на каждую локацию**
   (`DIMMD1`, `P1-DIMMB1`, …).

## Дедупликация (требование «триггер не дублируется»)

Каждый триггер-прототип настроен:
- **SINGLE** problem event — одно проблемное событие на переход в Problem;
- **recovery_mode = NONE** — никогда не снимается сам (записи SEL не стираются);
- **manual_close = YES** — закрывается только вручную.

Пока триггер «активен», новое событие той же ошибки в той же локации **не создаёт дубль**.
После устранения железа: очистите SEL (по желанию) и **закройте проблему вручную**.
Не закрывайте, пока ошибка физически не устранена — иначе триггер сработает заново.

Отдельный триггер `SEL collection failed` срабатывает, если SEL **не удалось прочитать**
(защита от «слепого» мониторинга) и восстанавливается автоматически.


```

## Ошибка `Failed to get SEL allocation info, Completion Code=FFh`

`FFh` — это стандартный код завершения IPMI **«unspecified error»** (неопределённая ошибка):
BMC отклонил команду `Get SEL Info` по внутренней причине, а не из-за синтаксиса. Типичные причины:

1. **Устаревшая/багованная прошивка BMC** — самая частая причина. Обновите BMC/IPMI
   до последней версии для конкретной платформы.
2. **Повреждённый или переполненный SEL** — проверьте `IPMICFG-Win.exe -sel info`;
   при необходимости `-sel del` (осторожно: стирает все записи) или холодный сброс BMC.
3. **Недостаточно прав** — IPMICFG без прав администратора не может обратиться к BMC.
   Агент должен работать от администратора.
4. **Несовпадение версии IPMICFG и поколения BMC** — обновите утилиту под платформу.
   (На X14/H14 IPMICFG не поддерживается — там нужен SAA/SSM.)

Порядок устранения: сначала обновите прошивку BMC и IPMICFG, затем проверьте права,
затем состояние SEL (`-sel info`), в крайнем случае — сброс BMC.

## Точки тонкой настройки (под реальные журналы)

Парсер написан по официальному User's Guide IPMICFG и приведённым двум вариантам вывода,
но у Supermicro много поколений BMC с разным текстом событий:

- **Классификация** (`Get-EventType`) — регулярки памяти/CPU/прочего.
- **Извлечение локации** (`Get-EventLocation`) — форматы `DIMMD1`, `P1-DIMMB1`,
  `CPU 0 DIMM 8`, `@DIMM…` и т.д.

Пришлите полные примеры вывода `IPMICFG-Win.exe -sel list -d 1` с разных платформ —
я откалибрую регулярки под реальные тексты.

## Примечания

- Скрипт выводит только ASCII (без кириллицы). Если добавите кириллицу — сохраняйте
  `.ps1` в UTF-8 **с BOM** (Windows PowerShell 5.1 иначе читает как ANSI).
