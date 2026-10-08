# 🧪 Закрытое тестирование v3.12.0-beta (RC1)

> Приватный стенд. Публичный релиз: `kronggg/padavan-warp-bypass`.
> НЕ распространять содержимое этого репозитория.

**Артефакт:** тег `v3.12.0-rc1` (commit `af0f1df`).
**sha256 tar.gz:** `8ee38e7305dd75151afd20f9bfcaf41714498b56cad5944c361e3728e27a3098`

---

## 1. Что проверяем (отличия от v3.11)

| Изменение | Зачем |
|---|---|
| Явные LOG-правила `PWB_LEARN` (TCP 80,443 + **UDP 443/QUIC**) | Автообучение работает явно, а не зависит от случайных dmesg-строк |
| Парсинг только своих строк + `sort -u` | Не захватывает чужой трафик, без дублей |
| Обрезка `learned_ips.cache` (2000) | Кэш не разрастается |
| `selftest.sh` | Однозначная проверка «в строю / не в строю» |
| `rollback.sh` (встроен в `install.sh`, работает **без сети**) | Возврат к снапшоту без потери связи |
| Снапшот `/etc/storage/pwb-backup-<ts>` перед установкой | Откат даже при офлайне |

**Главный риск теста:** правило `-m multiport` может не поддержаться ядром конкретной сборки.
Тогда TCP-обучение тихо не встанет, **UDP-правило останется**. Это и проверяем (шаг B).

---

## 2. Установка

Требования как в README: Padavan, **рабочий** AmneziaWG/WARP, SSH.

```sh
# 1) получить RC (на ПК): скачать репозиторий
#    https://github.com/kronggg/padavan-warp-bypass-testers  -> Code -> Download ZIP
#    или: git clone https://github.com/kronggg/padavan-warp-bypass-testers.git
# 2) скопировать на роутер
scp -r padavan-warp-bypass-testers/* admin@192.168.1.1:/tmp/pwb-rc/
# 3) войти и установить
ssh admin@192.168.1.1
cd /tmp/pwb-rc && sh install.sh
# 4) применить
reboot
```

> ⚠️ Устанавливать можно **поверх v3.11** — `install.sh` сначала делает снапшот.

---

## 3. Чек-лист теста (заполнить и вернуть)

Отмечать `[OK]/[FAIL]/[N/A]` и вставлять фактический вывод команд.

### A. Установка
- [ ] `install.sh` завершился без ошибок (`=== КОНЕЦ ===`)
- [ ] Появился снапшот: `ls -dt /etc/storage/pwb-backup-* | head -1`
- [ ] Файл версии: `cat /etc/storage/VERSION`

### B. Автообучение (ядро теста)
- [ ] LOG-правила встали: `iptables -t mangle -S PREROUTING | grep PWB_LEARN`
      *(жду: 2 строки — TCP `--dports 80,443` и UDP `--dport 443`)*
- [ ] После 1–2 мин трафика: `dmesg | grep -c PWB_LEARN` > 0
- [ ] Кэш растёт: `wc -l /etc/storage/learned_ips.cache`
- [ ] Новые адреса в ipset: `ipset list bypass_nets | grep 'Number of entries'`
- [ ] **КРИТИЧНО (проверка multiport):** `iptables -t mangle -S PREROUTING | grep -c 'dports 80,443'`
      → если `0`, ядро не поддержало multiport (ожидаемо для части сборок) — **сообщить обязательно**

### C. Само-проверка
- [ ] `sh /etc/storage/selftest.sh` → `FAIL=0` и «Система в строю»

### D. Откат (безопасность)
- [ ] `sh /etc/storage/rollback.sh` → восстановил скрипты, **интернет не пропал**
- [ ] После отката: `sh /etc/storage/selftest.sh` → состояние live (FAIL/WARN по факту)

### E. Устойчивость
- [ ] Перезагрузка: `reboot` → через 60 сек связь есть, `ip link show wg0` OK
- [ ] YouTube/Discord/Telegram открываются

---

## 4. Что сообщить

1. Вывод чек-листа (по пунктам).
2. `sh /etc/storage/selftest.sh` полностью.
3. Модель роутера и версия прошивки: `cat /etc/version 2>/dev/null; uname -a`
4. Если что-то сломалось — **сначала** `sh /etc/storage/rollback.sh`, затем лог.

Контакт для отчёта: Роман.
