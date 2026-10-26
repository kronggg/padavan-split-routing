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

# --- 6. dnsmasq-ipset (v3.13+: доменный список → bypass_nets) ---
if grep -q '# >>> PWB dnsmasq ipset >>>' /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null; then
    if pidof dnsmasq >/dev/null 2>&1; then
        # v3.15.1: проверяем ЭФФЕКТ (резолв → ipset), а не только наличие строки
        # busybox nslookup печатает 'Address: 1.2.3.4' = 2 поля — берём $2.
        # Перебираем до 5 доменов: первый в списке может быть не-FQDN ('.ua').
        _check=0
        _doms=$(sed -n '/# >>> PWB dnsmasq ipset >>>/,/# <<< PWB dnsmasq ipset <<</p' \
                /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null \
                | grep '^ipset=/' | sed 's|^ipset=/||; s|/[^/]*$||' | tr '/' '\n' \
                | grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])$' | head -5)
        for _d in $_doms; do
            _ips=$(nslookup "$_d" 127.0.0.1 2>/dev/null \
                   | awk -F': ' '/^Address/ { split($2,a," "); if (a[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && a[1] != "127.0.0.1") print a[1] }')
            [ -n "$_ips" ] || continue
            _ip=$(echo "$_ips" | head -1)
            if ipset test bypass_nets "$_ip" 2>&1 | grep -q 'is in set'; then
                ok "dnsmasq-ipset РАБОТАЕТ ($_d → $_ip в bypass_nets)"
                _check=2
                break
            fi
            fail "dnsmasq-ipset не применяется: $_d резолвится в $_ip, но его нет в bypass_nets"
            _check=2
            break
        done
        if [ "$_check" = "0" ]; then
            warn "dnsmasq-ipset: проверить не удалось (домены не резолвятся) — не ошибка"
        fi
    else
        warn "dnsmasq-ipset блок есть, но dnsmasq не запущен"
    fi
else
    fail "dnsmasq-ipset блок не найден (домены → bypass_nets)"
fi

# --- v3.15.3: IPv6-путь (AAAA → bypass_nets6) ---
if grep -q '^ipset=/' /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null; then
    if ! grep '^ipset=/' /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null | grep -q ',bypass_nets6'; then
        fail "IPv6: в конфиге указан только IPv4-набор — AAAA-адреса уходят мимо туннеля"
    elif ! ipset list bypass_nets6 >/dev/null 2>&1; then
        fail "IPv6: набор bypass_nets6 отсутствует"
    else
        _chk6=0
        _d6=$(sed -n '/# >>> PWB dnsmasq ipset >>>/,/# <<< PWB dnsmasq ipset <<</p' \
              /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null \
              | grep '^ipset=/' | sed 's|^ipset=/||; s|/[^/]*$||' | tr '/' '\n' \
              | grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])$' | head -5)
        for _dom in $_d6; do
            _a6=$(nslookup "$_dom" 127.0.0.1 2>/dev/null \
                  | awk -F': ' '/^Address/ { split($2,a," "); if (a[1] ~ /:/ && a[1] != "::1" && a[1] != "127.0.0.1") print a[1] }' | head -1)
            [ -n "$_a6" ] || continue
            _chk6=1
            if ipset test bypass_nets6 "$_a6" 2>&1 | grep -q 'is in set'; then
                ok "IPv6-обход РАБОТАЕТ ($_dom → $_a6 в bypass_nets6)"
            else
                fail "IPv6-обход не применяется: $_dom резолвится в $_a6, но его нет в bypass_nets6"
            fi
            break
        done
        if [ "$_chk6" = "0" ]; then
            warn "IPv6: у доменов списка нет AAAA-записей — проверить не удалось"
        fi
    fi
fi

# --- v3.15: blocked-only автообучение (PWB_PROBE) ---
if iptables -t mangle -S PREROUTING 2>/dev/null | grep -q 'PWB_PROBE'; then
    ok "LOG-правила PWB_PROBE (blocked-only) присутствуют"
else
    warn "LOG-правила PWB_PROBE отсутствуют (автообучение неактивно)"
fi
if [ -f /etc/storage/blocked_ips.cache ]; then
    BLC=$(wc -l < /etc/storage/blocked_ips.cache 2>/dev/null)
    ok "blocked_ips.cache: $BLC выученных (blocked-only)"
else
    warn "blocked_ips.cache пока не создан"
fi

# --- 7. Источники CIDR загружены? ---
if [ -f /etc/storage/bypass_nets.cidr ]; then
    CIDRS=$(wc -l < /etc/storage/bypass_nets.cidr 2>/dev/null)
    ok "bypass_nets.cidr: $CIDRS подсетей"
else
    warn "bypass_nets.cidr пока не создан"
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
