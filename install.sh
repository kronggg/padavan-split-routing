#!/bin/sh
# =============================================================================
#  Установщик системы селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.13.0 (dnsmasq-ipset: доменный список вместо автообучения)
# =============================================================================

echo "=== Установка системы селективной маршрутизации (AmneziaWG + WARP) v3.13.0 ==="

# -----------------------------------------------------------------------------
# 0. Снапшот текущей установки (для отката через rollback.sh)
# -----------------------------------------------------------------------------
BK_TS=$(date +%Y%m%d-%H%M%S)
BK_DIR="/etc/storage/pwb-backup-$BK_TS"
mkdir -p "$BK_DIR" 2>/dev/null
SNAP_OK=0
for f in route_watchdog.sh ipset_update.sh started_script.sh diagnostic.sh; do
    if [ -f "/etc/storage/$f" ]; then
        cp -a "/etc/storage/$f" "$BK_DIR/$f" 2>/dev/null && SNAP_OK=1
    fi
done
if [ -f /etc/storage/cron/crontabs/admin ]; then
    cp -a /etc/storage/cron/crontabs/admin "$BK_DIR/crontab.admin" 2>/dev/null && SNAP_OK=1
fi
if [ "$SNAP_OK" = "1" ]; then
    # Храним максимум 3 последних снапшота
    ls -dt /etc/storage/pwb-backup-* 2>/dev/null | tail -n +4 | while read old; do rm -rf "$old" 2>/dev/null; done
    echo "Снапшот создан: $BK_DIR (откат: sh /etc/storage/rollback.sh)"
else
    rmdir "$BK_DIR" 2>/dev/null
    echo "Снапшот не создан (нет предыдущей установки)"
fi

# -----------------------------------------------------------------------------
# 1. Создание основного скрипта ipset_update.sh
# -----------------------------------------------------------------------------
cat > /etc/storage/ipset_update.sh << 'EOF_SCRIPT'
#!/bin/sh
# -----------------------------------------------------------------------------
# Защита от повторного запуска
# -----------------------------------------------------------------------------
LOCK_FILE="/tmp/ipset_update.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "[$(date)] Скрипт уже выполняется, завершаюсь." >> /tmp/ipset_update.log
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# -----------------------------------------------------------------------------
# Настройки
# -----------------------------------------------------------------------------
IPSET_NAME="bypass_nets"
IPSET_TMP="${IPSET_NAME}_tmp"
IPSET6_NAME="bypass_nets6"
IPSET6_TMP="${IPSET6_NAME}_tmp"
VPN_IFACE="wg0"
TABLE_ID=51
MARK_VALUE="0xca6c"
LOG_FILE="/tmp/ipset_update.log"

CIDR_SOURCES="
https://raw.githubusercontent.com/you-oops-dev/resolving-public/main/unblock_suite_ip_ipset.txt
https://raw.githubusercontent.com/you-oops-dev/resolving-public/main/unblock_suite_ip.txt
https://antifilter.download/list/allyouneed.lst
https://community.antifilter.download/list/community.lst
https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/ipsum.lst
https://raw.githubusercontent.com/lord-alfred/ipranges/main/google/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/cloudflare/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/telegram/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/facebook/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/twitter/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/amazon/ipv4_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/microsoft/ipv4_merged.txt
"
# --- v3.13: доменный список для dnsmasq ---
# «Россия inside» = сервисные и медийные домены платформ (YouTube/Discord/Meta/Twitter/TikTok и др.). dnsmasq кладёт их IP в bypass_nets.
# Формат строк: ipset=/домен/…/set — подменяем имя set на ${IPSET_NAME}.
DNSMASQ_DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-ipset.lst"
DNSMASQ_SRC_SET="vpn_domains"   # имя set в исходном файле itdoginfo
DNSMASQ_CONF="/etc/storage/dnsmasq/dnsmasq.conf"
CIDR6_SOURCES="
https://raw.githubusercontent.com/lord-alfred/ipranges/main/telegram/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/facebook/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/google/ipv6_merged.txt
https://raw.githubusercontent.com/lord-alfred/ipranges/main/cloudflare/ipv6_merged.txt
"
MIN_ENTRIES=100

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "$msg"; echo "$msg" >> "$LOG_FILE"; }

# -----------------------------------------------------------------------------
# Ожидание полной готовности сети и VPN-туннеля
# -----------------------------------------------------------------------------
wait_for_network() {
    log "Ожидаю доступность WAN (макс 120s)..."
    local wan_ok=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 || wget -q --spider http://cp.cloudflare.com 2>/dev/null; then
            wan_ok=1
            break
        fi
        sleep 10
    done
    if [ $wan_ok -eq 0 ]; then
        log "ОШИБКА: WAN не доступен после 120 секунд"
        return 1
    fi
    log "WAN доступен"

    log "Ожидаю VPN-интерфейс $VPN_IFACE и handshake (макс 120s)..."
    local vpn_ok=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if ip link show "$VPN_IFACE" >/dev/null 2>&1; then
            if awg show "$VPN_IFACE" 2>/dev/null | grep -q "latest handshake"; then
                vpn_ok=1
                break
            elif wg show "$VPN_IFACE" 2>/dev/null | grep -q "latest handshake"; then
                vpn_ok=1
                break
            fi
        fi
        sleep 10
    done
    if [ $vpn_ok -eq 0 ]; then
        log "ОШИБКА: VPN handshake не установлен после 120 секунд"
        return 1
    fi
    log "$VPN_IFACE готов, handshake установлен"

    # Автоопределение параметров
    TABLE_ID=$(ip rule show | grep -E "fwmark 0x[0-9a-f]+.*lookup [0-9]+" | head -1 | sed -E 's/.*lookup ([0-9]+).*/\1/')
    [ -z "$TABLE_ID" ] && TABLE_ID=51

    if command -v wg >/dev/null 2>&1; then
        MARK_VALUE=$(wg show "$VPN_IFACE" fwmark 2>/dev/null | awk '{print $2}')
    elif command -v awg >/dev/null 2>&1; then
        MARK_VALUE=$(awg show "$VPN_IFACE" fwmark 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$MARK_VALUE" ]; then
        MARK_VALUE=$(ip rule show | grep -E "fwmark 0x[0-9a-f]+.*lookup $TABLE_ID" | head -1 | sed -E 's/.*fwmark (0x[0-9a-f]+).*/\1/')
    fi
    [ -z "$MARK_VALUE" ] && MARK_VALUE="0xca6c"

    log "Определены параметры: TABLE_ID=$TABLE_ID, MARK_VALUE=$MARK_VALUE"
    return 0
}

# -----------------------------------------------------------------------------
# Настройка policy routing
# -----------------------------------------------------------------------------
setup_policy_routing() {
    ip rule del pref 5182 2>/dev/null
    ip rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip route flush table "$TABLE_ID"
    ip route add default dev "$VPN_IFACE" table "$TABLE_ID"
    echo 0 > /proc/sys/net/ipv4/conf/"$VPN_IFACE"/rp_filter 2>/dev/null
    ip -6 rule del pref 5182 2>/dev/null
    ip -6 rule add fwmark "$MARK_VALUE" lookup "$TABLE_ID" pref 5182
    ip -6 route flush table "$TABLE_ID" 2>/dev/null
    ip -6 route add default dev "$VPN_IFACE" table "$TABLE_ID" 2>/dev/null
    sysctl -w net.ipv6.conf."$VPN_IFACE".rp_filter=0 2>/dev/null
    log "Policy routing: fwmark $MARK_VALUE -> table $TABLE_ID (dev $VPN_IFACE)"
}

# -----------------------------------------------------------------------------
# Настройка правил iptables
# -----------------------------------------------------------------------------
setup_iptables() {
    modprobe ip_set_hash_net 2>/dev/null
    modprobe xt_set 2>/dev/null
    modprobe xt_CONNMARK 2>/dev/null

    if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        ipset create "$IPSET_NAME" hash:net maxelem 100000 2>/dev/null
    fi

    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null
    iptables -t mangle -D PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE" 2>/dev/null
    iptables -t mangle -D PREROUTING ! -i "$VPN_IFACE" -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark 2>/dev/null

    iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$MARK_VALUE"
    iptables -t mangle -A PREROUTING -m set --match-set "$IPSET_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE"
    iptables -t mangle -A PREROUTING ! -i "$VPN_IFACE" -m connmark --mark "$MARK_VALUE" -j CONNMARK --restore-mark

    log "Правила iptables для $IPSET_NAME добавлены"
	
    # IPv6
    modprobe ip6_set 2>/dev/null
    modprobe ip6_set_hash_net 2>/dev/null
    if ! ipset list "$IPSET6_NAME" >/dev/null 2>&1; then
        ipset create "$IPSET6_NAME" hash:net family inet6 maxelem 50000 2>/dev/null
    fi
    ip6tables -t mangle -D PREROUTING -m set --match-set "$IPSET6_NAME" dst -j MARK --set-mark "$MARK_VALUE" 2>/dev/null
    ip6tables -t mangle -D PREROUTING -m set --match-set "$IPSET6_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE" 2>/dev/null
    ip6tables -t mangle -A PREROUTING -m set --match-set "$IPSET6_NAME" dst -j MARK --set-mark "$MARK_VALUE"
    ip6tables -t mangle -A PREROUTING -m set --match-set "$IPSET6_NAME" dst -j CONNMARK --set-mark "$MARK_VALUE"
	
    log "Правила ip6tables для $IPSET6_NAME добавлены"
}

# -----------------------------------------------------------------------------
# Обновление ipset из CIDR-списков
# -----------------------------------------------------------------------------
update_ipset() {
    log "=== ОБНОВЛЕНИЕ IPSET ИЗ CIDR-СПИСКОВ ==="
    local tmp_all="/tmp/cidr_all_raw.txt"
    > "$tmp_all"

    for url in $CIDR_SOURCES; do
        [ -z "$url" ] && continue
        log "Скачиваю: $url"
        wget -q -O - "$url" 2>/dev/null >> "$tmp_all"
    done

    local tmp_clean="/tmp/cidr_clean.txt"
    > "$tmp_clean"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp_all" 2>/dev/null | sort -u > "$tmp_clean"
    local count=$(wc -l < "$tmp_clean" 2>/dev/null)
    [ -z "$count" ] && count=0
    log "Найдено уникальных подсетей: $count"

    if [ "$count" -lt "$MIN_ENTRIES" ]; then
        log "ОШИБКА: слишком мало подсетей ($count), обновление прервано"
        rm -f "$tmp_all" "$tmp_clean"
        return 1
    fi

    modprobe ip_set_hash_net 2>/dev/null
    ipset create "$IPSET_TMP" hash:net maxelem 100000 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ОШИБКА: не удалось создать временный ipset"
        rm -f "$tmp_all" "$tmp_clean"
        return 1
    fi

    log "Импортирую подсети во временный ipset..."
    [ -f "$tmp_clean" ] || return 1
    while read cidr; do
        [ -z "$cidr" ] && continue
        ipset add "$IPSET_TMP" "$cidr" -exist 2>/dev/null
    done < "$tmp_clean"

    ipset swap "$IPSET_NAME" "$IPSET_TMP" 2>/dev/null || {
        ipset destroy "$IPSET_NAME" 2>/dev/null
        ipset rename "$IPSET_TMP" "$IPSET_NAME"
    }
    ipset destroy "$IPSET_TMP" 2>/dev/null

    # Сохраняем исходный CIDR-список для быстрого восстановления
    cp "$tmp_clean" /etc/storage/bypass_nets.cidr
    rm -f "$tmp_all" "$tmp_clean"
    log "Обновление завершено. Записей в $IPSET_NAME: $(ipset list $IPSET_NAME | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')"
    return 0
}

# -----------------------------------------------------------------------------
# Обновление ipset6 из IPv6 CIDR-списков
# -----------------------------------------------------------------------------
update_ipset6() {
    log "=== ОБНОВЛЕНИЕ IPv6 IPSET ==="
    local tmp6="/tmp/cidr6_raw.txt"
    > "$tmp6"
    for url in $CIDR6_SOURCES; do
        [ -z "$url" ] && continue
        log "Скачиваю IPv6: $url"
        wget -q -O - "$url" 2>/dev/null >> "$tmp6"
    done
    local tmp6_clean="/tmp/cidr6_clean.txt"
    > "$tmp6_clean"
    grep -E '^[0-9a-f:]+/[0-9]+$' "$tmp6" 2>/dev/null | sort -u > "$tmp6_clean"
    local count6=$(wc -l < "$tmp6_clean" 2>/dev/null)
    [ -z "$count6" ] && count6=0
    log "Найдено уникальных IPv6 подсетей: $count6"

    if [ "$count6" -gt 0 ]; then
        ipset create "$IPSET6_TMP" hash:net family inet6 maxelem 50000 2>/dev/null
        if [ $? -eq 0 ]; then
            while read cidr6; do
                [ -z "$cidr6" ] && continue
                ipset add "$IPSET6_TMP" "$cidr6" -exist 2>/dev/null
            done < "$tmp6_clean"
            ipset swap "$IPSET6_NAME" "$IPSET6_TMP" 2>/dev/null || {
                ipset destroy "$IPSET6_NAME" 2>/dev/null
                ipset rename "$IPSET6_TMP" "$IPSET6_NAME"
            }
            ipset destroy "$IPSET6_TMP" 2>/dev/null
        fi
    fi
    cp "$tmp6_clean" /etc/storage/bypass_nets6.cidr 2>/dev/null
    rm -f "$tmp6" "$tmp6_clean"
    log "IPv6 обновление завершено"
}

# -----------------------------------------------------------------------------
# v3.13: dnsmasq — доменный список → $IPSET_NAME
# dnsmasq сам добавляет IP в ipset при резолве домена (ipset=/…/bypass_nets).
# Точный only-list: в WARP попадают IP ТОЛЬКО доменов из доменного списка,
# а не «всё, к чему обращались» (в этом был баг learn-everything v3.12).
# -----------------------------------------------------------------------------
setup_dnsmasq() {
    log "=== DNSMASQ: доменный список → $IPSET_NAME ==="
    local tmp="/tmp/dnsmasq_domains.raw"
    local out="/tmp/dnsmasq_domains.ipset"
    wget -q -O "$tmp" "$DNSMASQ_DOMAINS_URL" 2>/dev/null
    if [ ! -s "$tmp" ]; then
        log "ОШИБКА: не скачал доменный список ($DNSMASQ_DOMAINS_URL)"
        rm -f "$tmp"
        return 1
    fi
    # Преобразуем имя set: …/vpn_domains → …/bypass_nets; берём только ipset=-строки
    grep '^ipset=/' "$tmp" | sed "s|/${DNSMASQ_SRC_SET}\$|/${IPSET_NAME}|" > "$out"
    local n=$(grep -c '^ipset=/' "$out" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" -lt 10 ]; then
        log "ОШИБКА: доменный список пуст/мал ($n строк) — dnsmasq не настраиваю"
        rm -f "$tmp" "$out"
        return 1
    fi
    local conf="$DNSMASQ_CONF"
    if [ ! -d "$(dirname "$conf")" ]; then
        conf="/etc/storage/dnsmasq.conf"
        log "WARN: $DNSMASQ_CONF недоступен — использую $conf"
    fi
    if [ -f "$conf" ]; then
        sed -i '/# >>> PWB dnsmasq ipset >>>/,/# <<< PWB dnsmasq ipset <<</d' "$conf" 2>/dev/null
    fi
    {
        echo "# >>> PWB dnsmasq ipset >>>"
        echo "# auto-generated $(date) — не редактировать вручную"
        cat "$out"
        echo "# <<< PWB dnsmasq ipset <<<"
    } >> "$conf"
    rm -f "$tmp" "$out"
    if pidof dnsmasq >/dev/null 2>&1; then
        killall -HUP dnsmasq 2>/dev/null
        log "dnsmasq: конфиг перечитан (HUP), доменов: $n"
    else
        log "dnsmasq: не запущен — конфиг записан, применится при старте (доменов: $n)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Главный блок
# -----------------------------------------------------------------------------
log "=== СТАРТ v3.13.0 ==="
if wait_for_network; then
    setup_policy_routing
    setup_iptables

    # Быстрое восстановление из локального CIDR-списка
    if [ -f /etc/storage/bypass_nets.cidr ]; then
        cidr_count=$(wc -l < /etc/storage/bypass_nets.cidr 2>/dev/null)
        if [ "$cidr_count" -ge "$MIN_ENTRIES" ]; then
            modprobe ip_set_hash_net 2>/dev/null
            log "Быстрое восстановление ipset из CIDR-списка ($cidr_count подсетей)..."
            {
                echo "create $IPSET_TMP hash:net maxelem 100000"
                sed "s/^/add $IPSET_TMP /" /etc/storage/bypass_nets.cidr
            } | ipset restore 2>/dev/null
            if [ $? -eq 0 ]; then
                ipset swap "$IPSET_NAME" "$IPSET_TMP" 2>/dev/null || {
                    ipset destroy "$IPSET_NAME" 2>/dev/null
                    ipset rename "$IPSET_TMP" "$IPSET_NAME"
                }
                ipset destroy "$IPSET_TMP" 2>/dev/null
                log "ipset восстановлен, пропускаю полное обновление"
            else
                log "Ошибка восстановления, запускаю полное обновление"
                update_ipset
            fi
        else
            log "CIDR-список повреждён, запускаю полное обновление"
            update_ipset
        fi
    else
        update_ipset
    fi

    # Быстрое восстановление IPv6 из CIDR-файла
    if [ -f /etc/storage/bypass_nets6.cidr ]; then
        cidr6_count=$(wc -l < /etc/storage/bypass_nets6.cidr 2>/dev/null)
        if [ "$cidr6_count" -gt 0 ]; then
            modprobe ip6_set_hash_net 2>/dev/null
            log "Быстрое восстановление ipset6 из CIDR-списка ($cidr6_count подсетей)..."
            {
                echo "create $IPSET6_TMP hash:net family inet6 maxelem 50000"
                sed "s/^/add $IPSET6_TMP /" /etc/storage/bypass_nets6.cidr
            } | ipset restore 2>/dev/null
            if [ $? -eq 0 ]; then
                ipset swap "$IPSET6_NAME" "$IPSET6_TMP" 2>/dev/null || {
                    ipset destroy "$IPSET6_NAME" 2>/dev/null
                    ipset rename "$IPSET6_TMP" "$IPSET6_NAME"
                }
                ipset destroy "$IPSET6_TMP" 2>/dev/null
                log "ipset6 восстановлен"
            fi
        fi
    fi

    # Если ipset6 всё ещё пуст — загружаем подсети
    entries6=$(ipset list "$IPSET6_NAME" 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    if [ -z "$entries6" ] || [ "$entries6" -lt 10 ]; then
        log "ipset6 содержит $entries6 записей, запускаю обновление IPv6"
        update_ipset6
    fi

    # v3.13: настраиваем dnsmasq (доменный список → $IPSET_NAME).
    # Заменяет автообучение/restore_learned: IP добавляет dnsmasq при
    # резолве доменов из доменного списка, плюс статические CIDR (update_ipset).
    setup_dnsmasq
else
    log "КРИТИЧЕСКАЯ ОШИБКА: сеть или VPN не готовы, завершаюсь"
    exit 1
fi
log "=== КОНЕЦ ==="
EOF_SCRIPT

chmod +x /etc/storage/ipset_update.sh

# -----------------------------------------------------------------------------
# 2. Создание watchdog (с поддержкой IPv6)
# -----------------------------------------------------------------------------
cat > /etc/storage/route_watchdog.sh << 'EOF_WATCHDOG'
#!/bin/sh
# Lock-файл: предотвращает запуск нескольких копий watchdog
LOCK_FILE="/tmp/route_watchdog.lock"
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

modprobe ip_set_hash_net 2>/dev/null
modprobe xt_set 2>/dev/null
modprobe ip6_set 2>/dev/null
modprobe ip6_set_hash_net 2>/dev/null

INTERVAL=15
WG0_WAIT_LOGGED=0        # флаг: сообщение 'wg0 не поднят' пишем один раз, без спама

# --- v3.13: IP попадают в bypass_nets ТОЛЬКО через dnsmasq (доменный список) ---
# или через статические CIDR-источники (см. ipset_update.sh).
# Автообучение по dmesg/LOG УДАЛЕНО: оно добавляло в WARP любой посещённый IP
# (learn-everything) — именно это гнало «обычные» сайты в туннель.

while true; do
    if ip rule show | grep -q "not.*fwmark 0xca6c"; then
        ip rule del pref 5182 2>/dev/null
        ip rule add fwmark 0xca6c lookup 51 pref 5182
        echo "[$(date)] Watchdog: удалено not-правило" >> /tmp/route_watchdog.log
    fi

    # wg0 может отсутствовать на ранней стадии загрузки — тогда wg0-операции
    # пропускаем молча (без спама в stderr); при появлении wg0 цикл подхватит.
    if ! ip link show wg0 >/dev/null 2>&1; then
        if [ "$WG0_WAIT_LOGGED" != "1" ]; then
            WG0_WAIT_LOGGED=1
            echo "[$(date)] Watchdog: wg0 ещё не поднят — маршрут/rp_filter пропущены" >> /tmp/route_watchdog.log
        fi
    else
        WG0_WAIT_LOGGED=0
        if ! ip route show table 51 | grep -q "default dev wg0"; then
            ip route replace default dev wg0 table 51 2>/dev/null
            echo "[$(date)] Watchdog: исправлен маршрут в table 51" >> /tmp/route_watchdog.log
        fi

        if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" != "0" ]; then
            # Проверяем путь явно: `echo > несуществующий_путь` печатает ошибку
            # редиректа ДО 2>/dev/null (шелл раскрывает редирект раньше) — так не шумим.
            if [ -f /proc/sys/net/ipv4/conf/wg0/rp_filter ]; then
                echo 0 > /proc/sys/net/ipv4/conf/wg0/rp_filter 2>/dev/null
                echo "[$(date)] Watchdog: исправлен rp_filter" >> /tmp/route_watchdog.log
            fi
        fi
    fi

    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило MARK" >> /tmp/route_watchdog.log
    fi

    if ! iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило CONNMARK save" >> /tmp/route_watchdog.log
    fi

    if ! iptables -t mangle -C PREROUTING ! -i wg0 -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A PREROUTING ! -i wg0 -m connmark --mark 0xca6c -j CONNMARK --restore-mark
        echo "[$(date)] Watchdog: добавлено правило CONNMARK restore" >> /tmp/route_watchdog.log
    fi

    # --- v3.13: LOG-правила автообучения УДАЛЕНЫ (learn-everything) ---
    # IP → bypass_nets добавляет dnsmasq при резолве доменов из доменного списка
    # (ipset=/…/bypass_nets), плюс статические CIDR. Здесь ничего не логируется.

    # Создание ipset6, если его ещё нет
    if ! ipset list bypass_nets6 >/dev/null 2>&1; then
        modprobe ip6_set_hash_net 2>/dev/null
        ipset create bypass_nets6 hash:net family inet6 maxelem 50000 2>/dev/null
        echo "[$(date)] Watchdog: создан ipset6 bypass_nets6" >> /tmp/route_watchdog.log
    fi

    # Проверка ip6tables MARK для IPv6
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило ip6tables MARK" >> /tmp/route_watchdog.log
    fi

    # Проверка ip6tables CONNMARK для IPv6
    if ! ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c
        echo "[$(date)] Watchdog: добавлено правило ip6tables CONNMARK" >> /tmp/route_watchdog.log
    fi

    ENTRIES=$(ipset list bypass_nets 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    if [ -n "$ENTRIES" ] && [ "$ENTRIES" -lt 100 ]; then
        if [ ! -f /tmp/ipset_update.lock ]; then
            echo "[$(date)] Watchdog: ipset почти пуст, запускаю обновление" >> /tmp/route_watchdog.log
            sh /etc/storage/ipset_update.sh &
        fi
    fi

    NOW=$(date +%s)
    sleep $INTERVAL
done
EOF_WATCHDOG

chmod +x /etc/storage/route_watchdog.sh

# -----------------------------------------------------------------------------
# 2b. rollback.sh — откат без сети (встроен, всегда доступен на роутере)
# -----------------------------------------------------------------------------
cat > /etc/storage/rollback.sh << 'EOF_ROLLBACK'
#!/bin/sh
# Откат к последнему снапшоту перед установкой. Не требует сети.
BKDIR="$1"
[ -z "$BKDIR" ] && BKDIR=$(ls -dt /etc/storage/pwb-backup-* 2>/dev/null | head -1)
echo "=== ROLLBACK ==="
if [ -z "$BKDIR" ] || [ ! -d "$BKDIR" ]; then
    echo "  [FAIL] снапшот не найден:"
    ls -dt /etc/storage/pwb-backup-* 2>/dev/null || echo "    (нет)"
    exit 1
fi
echo "  Снапшот: $BKDIR"
killall route_watchdog.sh 2>/dev/null
killall ipset_update.sh 2>/dev/null
rm -f /tmp/route_watchdog.lock /tmp/ipset_update.lock 2>/dev/null
for f in route_watchdog.sh ipset_update.sh started_script.sh diagnostic.sh; do
    [ -f "$BKDIR/$f" ] && cp -a "$BKDIR/$f" /etc/storage/"$f" && echo "  [OK] восстановлен $f"
done
if [ -f "$BKDIR/crontab.admin" ]; then
    cp -a "$BKDIR/crontab.admin" /etc/storage/cron/crontabs/admin 2>/dev/null && killall crond 2>/dev/null && crond && echo "  [OK] crontab"
fi
iptables -t mangle -D PREROUTING -m set ! --match-set bypass_nets dst -p tcp -m multiport --dports 80,443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_LEARN " 2>/dev/null
iptables -t mangle -D PREROUTING -m set ! --match-set bypass_nets dst -p udp --dport 443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_LEARN " 2>/dev/null
# v3.13: убираем блок dnsmasq селективности из конфига
DCONF="/etc/storage/dnsmasq/dnsmasq.conf"
[ -f "$DCONF" ] || DCONF="/etc/storage/dnsmasq.conf"
if [ -f "$DCONF" ]; then
    sed -i '/# >>> PWB dnsmasq ipset >>>/,/# <<< PWB dnsmasq ipset <<</d' "$DCONF" 2>/dev/null
    pidof dnsmasq >/dev/null 2>&1 && killall -HUP dnsmasq 2>/dev/null
fi
mtd_storage.sh save >/dev/null 2>&1
[ -x /etc/storage/route_watchdog.sh ] && /etc/storage/route_watchdog.sh & echo "  [OK] watchdog перезапущен"
echo "  ROLLBACK завершён. Проверь: sh /etc/storage/selftest.sh"
exit 0
EOF_ROLLBACK
chmod +x /etc/storage/rollback.sh

# -----------------------------------------------------------------------------
# 2c. selftest.sh — само-проверка (встроен, offline-доступен после отката)
# -----------------------------------------------------------------------------
cat > /etc/storage/selftest.sh << 'EOF_SELFTEST'
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
if grep -q '# >>> PWB dnsmasq ipset >>>' /etc/storage/dnsmasq/dnsmasq.conf 2>/dev/null \
   || grep -q '# >>> PWB dnsmasq ipset >>>' /etc/storage/dnsmasq.conf 2>/dev/null; then
    if pidof dnsmasq >/dev/null 2>&1; then
        ok "dnsmasq-ipset блок настроен и dnsmasq запущен"
    else
        warn "dnsmasq-ipset блок есть, но dnsmasq не запущен"
    fi
else
    fail "dnsmasq-ipset блок не найден (домены → bypass_nets)"
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
EOF_SELFTEST
chmod +x /etc/storage/selftest.sh

# -----------------------------------------------------------------------------
# 3. Настройка автозагрузки
# -----------------------------------------------------------------------------
cat > /etc/storage/started_script.sh << 'EOF_STARTED'
#!/bin/sh

# Принудительно включаем Cron (защита от выключения в веб-морде)
nvram set crond_enable=1
nvram commit
killall crond 2>/dev/null
crond

modprobe ip_set_hash_net
modprobe xt_set
modprobe ip6_set_hash_net

( sleep 60 && sh /etc/storage/ipset_update.sh ) &
( sleep 90 && /etc/storage/route_watchdog.sh & ) &
EOF_STARTED

chmod +x /etc/storage/started_script.sh

# Регистрируем started_script.sh в NVRAM boot script (выполняется при каждой загрузке)
nvram set script_aft_net_start="/etc/storage/started_script.sh" 2>/dev/null
nvram commit 2>/dev/null

# -----------------------------------------------------------------------------
# 4. Cron (каждые 6 часов)
# -----------------------------------------------------------------------------
if [ -d /etc/storage/cron/crontabs ]; then
    CRON_FILE="/etc/storage/cron/crontabs/admin"
    sed -i '/ipset_update.sh\|route_watchdog.sh/d' "$CRON_FILE" 2>/dev/null
    echo "0 */6 * * * sh /etc/storage/ipset_update.sh > /tmp/ipset_update_cron.log 2>&1" >> "$CRON_FILE"
	echo "@reboot /etc/storage/route_watchdog.sh &" >> "$CRON_FILE"
    # Принудительно включаем Cron в NVRAM — защита от выключенного Cron в веб-морде
    nvram set crond_enable=1 2>/dev/null
    nvram commit 2>/dev/null
    killall crond 2>/dev/null
    crond
fi

# -----------------------------------------------------------------------------
# 5. Сохранение и первый запуск
# -----------------------------------------------------------------------------
mtd_storage.sh save

echo "=============================================="
echo "Установка v3.13.0 завершена. Запускаю первый импорт..."
echo "=============================================="

# Устраняем возможный СТАРЫЙ инстанс watchdog/ipset_update.
# При переустановке поверх старой версии старый watchdog держал lock
# → новый инстанс выходил молча, и его правки не применялись.
killall route_watchdog.sh 2>/dev/null
killall ipset_update.sh 2>/dev/null
rm -f /tmp/route_watchdog.lock /tmp/ipset_update.lock 2>/dev/null

# v3.13 (C): сбрасываем старый кэш автообучения (learn-everything).
# Сам ipset перестраивается в update_ipset (swap из CIDR) — выученный мусор уйдёт.
rm -f /etc/storage/learned_ips.cache 2>/dev/null

sh /etc/storage/ipset_update.sh

# Запускаем watchdog сразу после первого импорта
/etc/storage/route_watchdog.sh &
