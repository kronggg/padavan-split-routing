# 🧪 Закрытое тестирование v3.13.0-rc1

> Приватный стенд. Публичный релиз: `kronggg/padavan-warp-bypass`.
> НЕ распространять содержимое этого репозитория.

**Артефакт:** тег `v3.13.0-rc1` — см. **Releases**.
**sha256 архива:** указан на странице релиза; сверьте после скачивания.

---

## 1. Что проверяем (отличия от v3.11/v3.12)

| Изменение | Зачем |
|---|---|
| **dnsmasq-native ipset**: при DNS-резолве домена из блок-листа dnsmasq сам кладёт его IP в `bypass_nets` (`ipset=/…/bypass_nets`) | В WARP попадают IP **только** доменов блок-листа, а не «всё, к чему обращались» (в этом был баг learn-everything v3.12) |
| **Автообучение по dmesg/LOG удалено** (`PWB_LEARN`, learning-цикл, `learned_ips.cache`) | Learn-everything гнал в туннель любой посещённый IP (2ip.ru → WARP) |
| **Починены CIDR-источники** (12): `1andrevich cidr.txt`→`ipsum.lst`; `runetfreedom`→`community.antifilter/community.lst`; `subnet.lst`(70)→`allyouneed.lst`(18261) | Битые/мёртвые URL давали 404 → пустой/узкий список |
| `selftest.sh` | Однозначная проверка «в строю / не в строю» |
| `rollback.sh` (встроен в `install.sh`, работает **без сети**) | Возврат к снапшоту без потери связи |
| Снапшот `/etc/storage/pwb-backup-<ts>` перед установкой | Откат даже при офлайне |

**Главный риск теста (смена философии):** в WARP идут IP доменов блок-листа + широкие CIDR
(Google/Amazon/Meta/Microsoft), а не «блокируемое по факту». Проверяем, что **обычные**
ресурсы (2ip.ru, yandex) идут **напрямую**, а блокируемые — через туннель.

---

## 2. Установка

Требования как в README: Padavan, **рабочий** AmneziaWG/WARP, SSH.

```sh
# Pinned-тег (без CDN-гонки):
curl -sL https://raw.githubusercontent.com/kronggg/padavan-warp-bypass/v3.13.0-rc1/install.sh | sh
```

> ⚠️ Устанавливать можно **поверх v3.11/v3.12** — `install.sh` сначала делает снапшот.

---

## 3. Чек-лист теста (заполнить и вернуть)

Отмечать `[OK]/[FAIL]/[N/A]` и вставлять фактический вывод команд.

### A. Установка
- [ ] `install.sh` завершился без ошибок (`=== КОНЕЦ ===`)
- [ ] В логе есть: `DNSMASQ: доменный блок-лист → bypass_nets` и `dnsmasq: конфиг перечитан (HUP), доменов: N`
- [ ] Появился снапшот: `ls -dt /etc/storage/pwb-backup-* | head -1`
- [ ] Файл версии: `cat /etc/storage/VERSION`

### B. dnsmasq-ipset (ядро теста)
- [ ] Блок в конфиге есть:
      `grep -c 'ipset=/.*/bypass_nets' /etc/storage/dnsmasq/dnsmasq.conf` *(ожидаем ~1183; путь может быть `/etc/storage/dnsmasq.conf`)*
- [ ] `pidof dnsmasq` → процесс есть
- [ ] **E2E:** `nslookup discord.com 127.0.0.1` → взять IP → `ipset test bypass_nets <IP>` → **member**
- [ ] `ipset list bypass_nets | grep 'Number of entries'` → растёт после DNS-запросов

### C. Само-проверка
- [ ] `sh /etc/storage/selftest.sh` → `FAIL=0` и «Система в строю»

### D. Ключевая проверка философии (главное!)
- [ ] В браузере **`2ip.ru`** → показывает **провайдера** (НЕ Cloudflare/WARP)
- [ ] `ipset test bypass_nets <IP 2ip.ru>` → **NOT** member *(если member — блок-лист слишком широкий, сообщить)*
- [ ] YouTube/Discord/Telegram → открываются (через туннель)

### E. Откат (безопасность)
- [ ] `sh /etc/storage/rollback.sh` → восстановил скрипты, **интернет не пропал**
- [ ] После отката: `sh /etc/storage/selftest.sh` → состояние live (FAIL/WARN по факту)

### F. Устойчивость
- [ ] Перезагрузка: `reboot` → через 60 сек связь есть, `ip link show wg0` OK
- [ ] После ребута блок dnsmasq на месте: `grep -c 'PWB dnsmasq ipset' /etc/storage/dnsmasq/dnsmasq.conf`

---

## 4. Что сообщить

1. Вывод чек-листа (по пунктам).
2. `sh /etc/storage/selftest.sh` полностью.
3. Модель роутера и версия прошивки: `cat /etc/version 2>/dev/null; uname -a`
4. Если что-то сломалось — **сначала** `sh /etc/storage/rollback.sh`, затем лог.

Контакт для отчёта: Роман.
