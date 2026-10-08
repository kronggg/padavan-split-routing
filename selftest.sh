#!/bin/sh
# =============================================================================
#  selftest.sh — само-проверка после установки (Padavan / BusyBox)
#  Возвращает 0, если система в строю; иначе ненулевой код.
#  Использование:  sh /etc/storage/selftest.sh   (или curl ... | sh)
# =============================================================================

FAIL=0
WARN=0
ok()   { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=============================================="
echo "   SELF-TEST селективной маршрутизации"
echo "=============================================="

# --- 1. Скрипты на месте ---
if [ -f /etc/storage/route_watchdog.sh ] && [ -x /etc/storage/route_watchdog.sh ]; then
    ok "route_watchdog.sh на месте и исполняем"
else
    fail "route_watchdog.sh отсутствует/не исполняем"
fi
if [ -f /etc/storage/ipset_update.sh ]; then
    ok "ipset_update.sh на месте"
else
    fail "ipset_update.sh отсутствует"
fi

# --- 2. VPN-интерфейс ---
if ip link show wg0 >/dev/null 2>&1; then
    ok "интерфейс wg0 существует"
else
    fail "интерфейс wg0 отсутствует (VPN не поднят?)"
fi

# --- 3. ipset ---
if ipset list bypass_nets >/dev/null 2>&1; then
    ENTRIES=$(ipset list bypass_nets 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    if [ -n "$ENTRIES" ] && [ "$ENTRIES" -gt 0 ]; then
        ok "ipset bypass_nets: $ENTRIES записей"
    else
        fail "ipset bypass_nets пуст"
    fi
else
    fail "ipset bypass_nets не создан"
fi

# --- 4. Правила iptables (MARK / CONNMARK restore) ---
if iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null; then
    ok "правило MARK присутствует"
else
    fail "правило MARK отсутствует"
fi
if iptables -t mangle -C PREROUTING ! -i wg0 -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null \
   || iptables -t mangle -C PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
    ok "правило CONNMARK restore присутствует"
else
    fail "правило CONNMARK restore отсутствует"
fi

# --- 5. Policy routing ---
if ip rule show 2>/dev/null | grep -q "fwmark 0xca6c lookup 51"; then
    ok "ip rule (fwmark 0xca6c -> table 51) присутствует"
else
    fail "ip rule отсутствует"
fi
if ip route show table 51 2>/dev/null | grep -q "default dev wg0"; then
    ok "маршрут table 51 -> wg0 присутствует"
else
    fail "маршрут table 51 -> wg0 отсутствует"
fi

# --- 6. LOG-правила автообучения (v3.12+) ---
if iptables -t mangle -S PREROUTING 2>/dev/null | grep -q 'PWB_LEARN'; then
    ok "LOG-правила автообучения (PWB_LEARN) присутствуют"
else
    warn "LOG-правила автообучения (PWB_LEARN) отсутствуют (v3.12?)"
fi

# --- 7. Автообучение живое? ---
if [ -f /etc/storage/learned_ips.cache ]; then
    LEARNED=$(wc -l < /etc/storage/learned_ips.cache 2>/dev/null)
    ok "learned_ips.cache: $LEARNED записей"
else
    warn "learned_ips.cache пока не создан (нужен трафик ~1-2 мин)"
fi

# --- 8. Cron ---
if [ -f /etc/storage/cron/crontabs/admin ]; then
    if grep -q 'route_watchdog.sh' /etc/storage/cron/crontabs/admin 2>/dev/null; then
        ok "запись route_watchdog в cron присутствует"
    else
        warn "запись route_watchdog в cron отсутствует"
    fi
fi

echo "=============================================="
echo "   ИТОГ: FAIL=$FAIL  WARN=$WARN"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    echo "  СИСТЕМА НЕ В СТРОЮ — см. FAIL выше"
    exit 1
fi
echo "  Система в строю."
exit 0
