#!/bin/sh
# =============================================================================
#  rollback.sh — откат к последнему снапшоту перед установкой (Padavan/BusyBox)
#  install.sh делает снапшот в /etc/storage/pwb-backup-<ver>-<ts>/.
#  Возвращает рабочее состояние БЕЗ ребута, если возможно.
#  Использование:  sh /etc/storage/rollback.sh [путь_к_снапшоту]
# =============================================================================

BKDIR="$1"
if [ -z "$BKDIR" ]; then
    BKDIR=$(ls -dt /etc/storage/pwb-backup-* 2>/dev/null | head -1)
fi

echo "=============================================="
echo "   ROLLBACK селективной маршрутизации"
echo "=============================================="

if [ -z "$BKDIR" ] || [ ! -d "$BKDIR" ]; then
    echo "  [FAIL] снапшот не найден. Доступные:"
    ls -dt /etc/storage/pwb-backup-* 2>/dev/null || echo "    (нет)"
    exit 1
fi
echo "  Снапшот: $BKDIR"

# --- Остановить текущие процессы ---
killall route_watchdog.sh 2>/dev/null
killall ipset_update.sh 2>/dev/null
rm -f /tmp/route_watchdog.lock /tmp/ipset_update.lock 2>/dev/null

# --- Восстановить файлы ---
for f in route_watchdog.sh ipset_update.sh started_script.sh diagnostic.sh; do
    if [ -f "$BKDIR/$f" ]; then
        cp -a "$BKDIR/$f" /etc/storage/"$f" && echo "  [OK] восстановлен $f"
    else
        echo "  [SKIP] в снапшоте нет $f"
    fi
done

# --- Восстановить cron, если был ---
if [ -f "$BKDIR/crontab.admin" ]; then
    cp -a "$BKDIR/crontab.admin" /etc/storage/cron/crontabs/admin 2>/dev/null && {
        echo "  [OK] восстановлен crontab"
        killall crond 2>/dev/null; crond
    }
fi

# --- v3.13: LOG-правил автообучения больше нет. Defensive-чистка на случай остатка от v3.12 ---
iptables -t mangle -D PREROUTING -m set ! --match-set bypass_nets dst -p tcp -m multiport --dports 80,443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_LEARN " 2>/dev/null
iptables -t mangle -D PREROUTING -m set ! --match-set bypass_nets dst -p udp --dport 443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_LEARN " 2>/dev/null

# --- Сохранить и перезапустить ---
mtd_storage.sh save >/dev/null 2>&1
if [ -x /etc/storage/route_watchdog.sh ]; then
    /etc/storage/route_watchdog.sh &
    echo "  [OK] watchdog перезапущен"
fi

echo "==="
echo "  ROLLBACK завершён. Прогони диагностику: sh /etc/storage/diagnostic.sh"
echo "  (для полного применения правок ядра — опционально перезагрузка)"
exit 0
