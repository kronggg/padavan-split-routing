#!/bin/sh
# =============================================================================
#  Установщик системы селективной маршрутизации через AmneziaWG/WARP для Padavan
#  Версия 3.16.2-beta (dnsmasq-ipset + blocked-only автообучение)
# =============================================================================

echo "=== Установка системы селективной маршрутизации (AmneziaWG + WARP) v3.16.2-beta ==="

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
    # Отключаем rp_filter для VPN-интерфейса (необходимо для обратного трафика)
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
    # v3.15.3: модуля ip6_set_hash_net не существует — IPv6-наборы обслуживает ip_set_hash_net
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
    # v3.15.3: двойной набор — IPv4 идёт в bypass_nets, IPv6 (AAAA) в bypass_nets6.
    # dnsmasq раскладывает адреса по семействам сам; один набор IPv6 не примет.
    grep '^ipset=/' "$tmp" | sed "s|/${DNSMASQ_SRC_SET}\$|/${IPSET_NAME},${IPSET6_NAME}|" > "$out"
    local n=$(grep -c '^ipset=/' "$out" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" -lt 10 ]; then
        log "ОШИБКА: доменный список пуст/мал ($n строк) — dnsmasq не настраиваю"
        rm -f "$tmp" "$out"
        return 1
    fi
    local conf="$DNSMASQ_CONF"
    # v3.15.1: канонический путь. Корневой /etc/storage/dnsmasq.conf НЕ включён
    # через conf-file в /etc/dnsmasq.conf → dnsmasq его не читает, писать туда нельзя.
    if [ ! -d "$(dirname "$conf")" ]; then
        mkdir -p "$(dirname "$conf")" 2>/dev/null
    fi
    if [ ! -w "$(dirname "$conf")" ]; then
        log "ОШИБКА: каталог $(dirname "$conf") недоступен для записи — dnsmasq не настраиваю"
        rm -f "$tmp" "$out"
        return 1
    fi
    # v3.15.3: оба набора должны существовать ДО рестарта, иначе dnsmasq
    # не сможет записать в них адреса и молча потеряет часть резолвов.
    ipset list "$IPSET_NAME" >/dev/null 2>&1 || \
        ipset create "$IPSET_NAME" hash:net maxelem 100000 2>/dev/null
    ipset list "$IPSET6_NAME" >/dev/null 2>&1 || \
        ipset create "$IPSET6_NAME" hash:net family inet6 maxelem 50000 2>/dev/null
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
    # v3.15.1: SIGHUP НЕ перечитывает конфиг dnsmasq (только /etc/hosts + кэш).
    # Для применения ipset=/address= нужен ПОЛНЫЙ рестарт демона.
    if pidof dnsmasq >/dev/null 2>&1; then
        killall dnsmasq 2>/dev/null
        _i=0
        while [ -n "$(pidof dnsmasq 2>/dev/null)" ] && [ "$_i" -lt 10 ]; do
            sleep 1; _i=$((_i + 1))
        done
        # Защита от ложного успеха: если старый процесс не умер, новый экземпляр
        # не стартует, но pidof покажет СТАРЫЙ pid — лог соврёт «применён».
        if [ -n "$(pidof dnsmasq 2>/dev/null)" ]; then
            log "ОШИБКА: dnsmasq не остановился за 10 с — конфиг НЕ применён"
            return 1
        fi
        dnsmasq 2>/dev/null
        _i=0
        while [ -z "$(pidof dnsmasq 2>/dev/null)" ] && [ "$_i" -lt 10 ]; do
            sleep 1; _i=$((_i + 1))
        done
        if pidof dnsmasq >/dev/null 2>&1; then
            sleep 1
            log "dnsmasq: перезапущен (конфиг применён), доменов: $n"
        else
            log "ОШИБКА: dnsmasq не поднялся — конфиг записан, но НЕ применён"
            return 1
        fi
    else
        log "dnsmasq: не запущен — конфиг записан, применится при старте (доменов: $n)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Главный блок
# -----------------------------------------------------------------------------
log "=== СТАРТ v3.16.2-beta ==="
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
            # v3.15.3: ip6_set_hash_net не существует
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

# -----------------------------------------------------------------------------
# 2. Права на выполнение основного скрипта
# -----------------------------------------------------------------------------
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
# v3.15.3: ip6_set_hash_net не существует — IPv6-наборы обслуживает ip_set_hash_net

INTERVAL=15
WG0_WAIT_LOGGED=0        # флаг: сообщение 'wg0 не поднят' пишем один раз, без спама

# --- v3.15: blocked-only автообучение (PWB_PROBE) ---
# Кандидаты (DST вне bypass_nets, TCP 80/443 / UDP 443) берём из kernel-лога,
# затем ПРОВЕРЯЕМ прямым соединением; в bypass_nets попадают ТОЛЬКО заблокированные
# (проба не прошла). Доступные сайты остаются DIRECT — без регресса learn-everything.
PROBE_TIMEOUT=2
PROBE_INTERVAL=60
PROBE_MAX_CYCLE=8
PROBE_CACHE="/etc/storage/blocked_ips.cache"
LAST_PROBE=0

# probe_reachable IP PORT -> 0 = доступен (НЕ блокирован), !=0 = блок/недоступен
# Детектор инструментов обходом PATH: BusyBox `command -v`/`type` ненадёжны
# (возвращают 0 для отсутствующего бинаря) — поэтому проверяем сами.
_probe_have() {
    _oldifs=$IFS; IFS=:
    for _d in $PATH; do
        [ -n "$_d" ] || _d=.
        if [ -x "$_d/$1" ]; then IFS=$_oldifs; return 0; fi
    done
    IFS=$_oldifs
    return 1
}
probe_reachable() {
    if _probe_have nc; then
        nc -w "$PROBE_TIMEOUT" "$1" "$2" </dev/null >/dev/null 2>&1
        return $?
    elif _probe_have wget; then
        wget --spider -T "$PROBE_TIMEOUT" -t 1 -q "http://$1:$2" >/dev/null 2>&1
        return $?
    fi
    return 0   # нет nc/wget -> fail-safe: считаем доступным, НЕ учим
}

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

    # --- v3.15: LOG-правила blocked-only автообучения (PWB_PROBE) ---
    # Кандидаты: DST вне bypass_nets, TCP 80/443 и UDP 443. Rate-limit против флуда.
    if ! iptables -t mangle -C PREROUTING -m set ! --match-set bypass_nets dst -p tcp -m multiport --dports 80,443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_PROBE " 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set ! --match-set bypass_nets dst -p tcp -m multiport --dports 80,443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_PROBE " 2>/dev/null
        echo "[$(date)] Watchdog: добавлено LOG-правило PWB_PROBE (tcp)" >> /tmp/route_watchdog.log
    fi
    if ! iptables -t mangle -C PREROUTING -m set ! --match-set bypass_nets dst -p udp --dport 443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_PROBE " 2>/dev/null; then
        iptables -t mangle -A PREROUTING -m set ! --match-set bypass_nets dst -p udp --dport 443 -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "PWB_PROBE " 2>/dev/null
        echo "[$(date)] Watchdog: добавлено LOG-правило PWB_PROBE (udp)" >> /tmp/route_watchdog.log
    fi

    # --- v3.15: blocked-only learning (раз в PROBE_INTERVAL) ---
    NOW=$(date +%s)
    if [ "$((NOW - LAST_PROBE))" -ge "$PROBE_INTERVAL" ]; then
        LAST_PROBE=$NOW
        # восстановление из кэша: update_ipset пересобирает set из CIDR — выученное теряется
        if [ -f "$PROBE_CACHE" ]; then
            while read -r r_ip; do
                [ -n "$r_ip" ] || continue
                ipset add bypass_nets "$r_ip" -exist 2>/dev/null
            done < "$PROBE_CACHE"
        fi
        # кандидаты из kernel-лога (DST вне bypass_nets)
        dmesg 2>/dev/null | grep 'PWB_PROBE' | sed -n 's/.*DST=\([0-9.]*\).*DPT=\([0-9]*\).*/\1 \2/p' | sort -u > /tmp/pwb_cand.tmp
        dmesg -c >/dev/null 2>&1
        n=0
        while read -r c_ip c_port; do
            [ -n "$c_ip" ] || continue
            [ "$n" -ge "$PROBE_MAX_CYCLE" ] && break
            ipset test bypass_nets "$c_ip" 2>/dev/null && continue
            n=$((n+1))
            if probe_reachable "$c_ip" "$c_port"; then
                :   # доступен -> DIRECT, не учим
            else
                ipset add bypass_nets "$c_ip" -exist 2>/dev/null
                grep -qxF "$c_ip" "$PROBE_CACHE" 2>/dev/null || echo "$c_ip" >> "$PROBE_CACHE"
                echo "[$(date)] Watchdog: LEARN (blocked) $c_ip:$c_port" >> /tmp/route_watchdog.log
            fi
        done < /tmp/pwb_cand.tmp
        rm -f /tmp/pwb_cand.tmp
    fi

    # Создание ipset6, если его ещё нет
    if ! ipset list bypass_nets6 >/dev/null 2>&1; then
        # v3.15.3: ip6_set_hash_net не существует
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
# v3.15.1: только канонический путь (корневой dnsmasq не читает)
DCONF="/etc/storage/dnsmasq/dnsmasq.conf"
if [ -f "$DCONF" ]; then
    sed -i '/# >>> PWB dnsmasq ipset >>>/,/# <<< PWB dnsmasq ipset <<</d' "$DCONF" 2>/dev/null
    # v3.15.1: HUP не применяет изменения — нужен полный рестарт
    if pidof dnsmasq >/dev/null 2>&1; then
        killall dnsmasq 2>/dev/null
        _i=0
        while [ -n "$(pidof dnsmasq 2>/dev/null)" ] && [ "$_i" -lt 10 ]; do
            sleep 1; _i=$((_i + 1))
        done
        dnsmasq 2>/dev/null
        sleep 2
    fi
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

# --- 9. Менеджер доменов и веб-страница (v3.16) ---
if [ -x /etc/storage/bypass_domains.sh ]; then
    ok "bypass_domains.sh на месте и исполняем"
else
    fail "bypass_domains.sh отсутствует"
fi
if [ -f /etc/storage/pwb-web/bypass.html ]; then
    ok "веб-страница (мастер-копия) на месте"
else
    warn "веб-страница не установлена"
fi
if [ -f /opt/share/www/custom/index.html ]; then
    ok "страница развёрнута в слот /custom"
else
    warn "страница не развёрнута в /opt (выполните pwb_web_setup.sh stage)"
fi
if grep -qF '# >>> PWB web stage >>>' /etc/storage/started_script.sh 2>/dev/null; then
    ok "boot-хук страницы прописан (переживёт перезагрузку)"
else
    warn "boot-хук страницы отсутствует — после reboot слот опустеет"
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
# 2d. diagnostic.sh — расширенная диагностика (встроен, доступен offline)
# -----------------------------------------------------------------------------
cat > /etc/storage/diagnostic.sh << 'EOF_DIAG'
#!/bin/sh
# =============================================================================
#  diagnostic.sh — расширенная диагностика системы селективной маршрутизации
#  Версия 3.16.2-beta (Padavan / BusyBox). Возвращает 0 при отсутствии ошибок.
#  Использование:  sh /etc/storage/diagnostic.sh   (или curl ... | sh)
# =============================================================================

echo ""
echo "=============================================="
echo "  ДИАГНОСТИКА СИСТЕМЫ СЕЛЕКТИВНОЙ МАРШРУТИЗАЦИИ v3.16.2-beta"
echo "=============================================="
echo ""

IPSET_NAME="bypass_nets"
IPSET6_NAME="bypass_nets6"
ERRORS=0
WARNINGS=0
RECOMMENDATIONS=""

# -----------------------------------------------------------------------------
# 1. Модули ядра
# -----------------------------------------------------------------------------
echo "--- 1. Модули ядра ---"
if lsmod | grep -q ip_set_hash_net; then
    echo "  [OK] ip_set_hash_net загружен"
else
    echo "  [FAIL] ip_set_hash_net НЕ загружен"
    ERRORS=$((ERRORS+1))
fi

# v3.15.3: модуля ip6_set_hash_net не существует — IPv6-наборы обслуживает
# ip_set_hash_net (семейство задаётся при создании набора: family inet6).
# Проверяем не имя модуля, а фактическую способность создать IPv6-набор.
if ipset list "$IPSET6_NAME" >/dev/null 2>&1; then
    _v6n=$(ipset list "$IPSET6_NAME" 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    echo "  [OK] IPv6-набор $IPSET6_NAME работает (записей: ${_v6n:-0})"
else
    echo "  [FAIL] IPv6-набор $IPSET6_NAME отсутствует — IPv6-адреса не пойдут в туннель"
    ERRORS=$((ERRORS+1))
fi
if lsmod | grep -q xt_set; then
    echo "  [OK] xt_set загружен"
else
    echo "  [WARN] xt_set НЕ загружен"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 2. VPN-туннель
# -----------------------------------------------------------------------------
echo "--- 2. Состояние VPN-туннеля (wg0) ---"
if ip link show wg0 >/dev/null 2>&1; then
    echo "  [OK] Интерфейс wg0 существует"
    STATE=$(ip link show wg0 | grep -oE 'state [A-Z]+' | awk '{print $2}')
    echo "  [OK] Состояние: $STATE"
    IP=$(ip -4 addr show wg0 | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    [ -n "$IP" ] && echo "  [OK] IPv4 адрес: $IP" || { echo "  [FAIL] IPv4 адрес отсутствует"; ERRORS=$((ERRORS+1)); }
    if curl --interface wg0 --max-time 5 -s -o /dev/null -w "%{http_code}" http://cp.cloudflare.com | grep -qE "200|204|301|302"; then
        echo "  [OK] Трафик через туннель проходит"
    else
        echo "  [WARN] Трафик через туннель не проходит"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] Интерфейс wg0 НЕ НАЙДЕН"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 3. ipset (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 3. Состояние ipset ---"
if ipset list bypass_nets >/dev/null 2>&1; then
    ENTRIES=$(ipset list bypass_nets | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    echo "  [OK] ipset bypass_nets существует (записей: $ENTRIES)"
    if [ "$ENTRIES" -lt 1000 ]; then
        echo "  [WARN] Подозрительно мало записей, возможно, требуется обновление"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] ipset bypass_nets НЕ СУЩЕСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

if ipset list bypass_nets6 >/dev/null 2>&1; then
    ENTRIES6=$(ipset list bypass_nets6 | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
    echo "  [OK] ipset bypass_nets6 существует (записей: $ENTRIES6)"
    if [ "$ENTRIES6" -lt 10 ]; then
        echo "  [WARN] Слишком мало IPv6 подсетей, возможно, не обновлялся"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] ipset bypass_nets6 НЕ СУЩЕСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 4. Правила iptables (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 4. Правила iptables (mangle PREROUTING) ---"
if iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j MARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило MARK (IPv4) присутствует"
else
    echo "  [FAIL] Правило MARK (IPv4) ОТСУТСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi
if iptables -t mangle -C PREROUTING -m set --match-set bypass_nets dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило CONNMARK save (IPv4) присутствует"
else
    echo "  [WARN] Правило CONNMARK save (IPv4) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if iptables -t mangle -C PREROUTING ! -i wg0 -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
    echo "  [OK] Правило CONNMARK restore (IPv4) присутствует"
else
    # fallback: проверяем без ! -i wg0 (старая версия)
    if iptables -t mangle -C PREROUTING -m connmark --mark 0xca6c -j CONNMARK --restore-mark 2>/dev/null; then
        echo "  [OK] Правило CONNMARK restore (IPv4) присутствует"
    else
        echo "  [WARN] Правило CONNMARK restore (IPv4) отсутствует"
        WARNINGS=$((WARNINGS+1))
    fi
fi

if ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j MARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило MARK (IPv6) присутствует"
else
    echo "  [WARN] Правило MARK (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if ip6tables -t mangle -C PREROUTING -m set --match-set bypass_nets6 dst -j CONNMARK --set-mark 0xca6c 2>/dev/null; then
    echo "  [OK] Правило CONNMARK save (IPv6) присутствует"
else
    echo "  [WARN] Правило CONNMARK save (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

# --- Проверка dnsmasq-ipset (v3.13: доменный список → bypass_nets) ---
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
                echo "  [OK] dnsmasq-ipset РАБОТАЕТ ($_d → $_ip в bypass_nets)"
                _check=2
                break
            fi
            echo "  [FAIL] dnsmasq-ipset не применяется: $_d резолвится в $_ip, но его нет в bypass_nets"
            ERRORS=$((ERRORS+1))
            _check=2
            break
        done
        if [ "$_check" = "0" ]; then
            echo "  [WARN] dnsmasq-ipset: проверить не удалось (домены не резолвятся) — не ошибка"
            WARNINGS=$((WARNINGS+1))
        fi
    else
        echo "  [WARN] dnsmasq-ipset блок есть, dnsmasq не запущен"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [FAIL] dnsmasq-ipset блок не найден (домены → bypass_nets)"
    ERRORS=$((ERRORS+1))
fi

# --- Проверка blocked-only автообучения (v3.15) ---
if iptables -t mangle -S PREROUTING 2>/dev/null | grep -q 'PWB_PROBE'; then
    echo "  [OK] LOG-правила PWB_PROBE (blocked-only) присутствуют"
else
    echo "  [WARN] LOG-правила PWB_PROBE отсутствуют (автообучение неактивно)"
    WARNINGS=$((WARNINGS+1))
fi
if [ -f /etc/storage/blocked_ips.cache ]; then
    BLC=$(wc -l < /etc/storage/blocked_ips.cache 2>/dev/null)
    echo "  [OK] blocked_ips.cache: ${BLC} выученных (blocked-only)"
else
    echo "  [WARN] blocked_ips.cache отсутствует (ещё не обучались)"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 5. Policy routing (IPv4 и IPv6)
# -----------------------------------------------------------------------------
echo "--- 5. Policy routing ---"
RULE=$(ip rule show | grep 5182)
if echo "$RULE" | grep -q "fwmark 0xca6c lookup 51" && ! echo "$RULE" | grep -q "not"; then
    echo "  [OK] Правило ip rule (IPv4) корректно"
else
    echo "  [FAIL] Правило ip rule (IPv4) НЕКОРРЕКТНО: $RULE"
    ERRORS=$((ERRORS+1))
fi
if ip route show table 51 | grep -q "default dev wg0"; then
    echo "  [OK] Маршрут в таблице 51 (IPv4): default dev wg0"
else
    echo "  [FAIL] Маршрут в таблице 51 (IPv4) ОТСУТСТВУЕТ"
    ERRORS=$((ERRORS+1))
fi

if ip -6 rule show | grep -q "5182.*fwmark 0xca6c lookup 51"; then
    echo "  [OK] Правило ip -6 rule (IPv6) присутствует"
else
    echo "  [WARN] Правило ip -6 rule (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if ip -6 route show table 51 | grep -q "default dev wg0"; then
    echo "  [OK] Маршрут в таблице 51 (IPv6): default dev wg0"
else
    echo "  [WARN] Маршрут в таблице 51 (IPv6) отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" = "0" ]; then
    echo "  [OK] rp_filter для wg0 = 0"
else
    echo "  [WARN] rp_filter для wg0 != 0"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 6. Watchdog
# -----------------------------------------------------------------------------
echo "--- 6. Watchdog ---"
if ps | grep -q '[r]oute_watchdog'; then
    echo "  [OK] Процесс watchdog запущен"
else
    echo "  [FAIL] Процесс watchdog НЕ ЗАПУЩЕН"
    ERRORS=$((ERRORS+1))
fi

# -----------------------------------------------------------------------------
# 7. Лог основного скрипта
# -----------------------------------------------------------------------------
echo "--- 7. Лог основного скрипта (ipset_update.sh) ---"
if [ -f /tmp/ipset_update.log ]; then
    LAST_END=$(grep "=== КОНЕЦ ===" /tmp/ipset_update.log | tail -1)
    if [ -n "$LAST_END" ]; then
        echo "  [OK] Последний запуск успешен"
    else
        echo "  [WARN] Нет подтверждения успешного завершения"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] Лог отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 8. Автозагрузка
# -----------------------------------------------------------------------------
echo "--- 8. Автозагрузка ---"
if grep -q "ipset_update.sh" /etc/storage/started_script.sh; then
    echo "  [OK] ipset_update.sh прописан в started_script.sh"
else
    echo "  [FAIL] ipset_update.sh НЕ ПРОПИСАН"
    ERRORS=$((ERRORS+1))
fi
if grep -q "ip_set_hash_net" /etc/storage/started_script.sh; then
    echo "  [OK] Модуль ip_set_hash_net загружается при старте"
else
    echo "  [WARN] Модуль ip_set_hash_net НЕ загружается при старте"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 9. Источники CIDR (доменный список → bypass_nets)
# -----------------------------------------------------------------------------
echo "--- 9. Источники CIDR ---"
if [ -f /etc/storage/bypass_nets.cidr ]; then
    CIDRS=$(wc -l < /etc/storage/bypass_nets.cidr 2>/dev/null)
    echo "  [OK] bypass_nets.cidr: ${CIDRS} подсетей"
    if [ "${CIDRS:-0}" -lt 100 ]; then
        echo "  [WARN] Подозрительно мало подсетей в bypass_nets.cidr"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] bypass_nets.cidr отсутствует (обновление ещё не выполнялось?)"
    WARNINGS=$((WARNINGS+1))
fi
if [ -f /etc/storage/bypass_nets6.cidr ]; then
    CIDRS6=$(wc -l < /etc/storage/bypass_nets6.cidr 2>/dev/null)
    echo "  [OK] bypass_nets6.cidr: ${CIDRS6} подсетей"
else
    echo "  [WARN] bypass_nets6.cidr отсутствует (IPv6-список не создан)"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 10. Планировщик (cron)
# -----------------------------------------------------------------------------
echo "--- 10. Планировщик (cron) ---"
CRON_FILE="/etc/storage/cron/crontabs/admin"
if [ -f "$CRON_FILE" ]; then
    if grep -q 'ipset_update.sh' "$CRON_FILE" 2>/dev/null; then
        echo "  [OK] ipset_update.sh в cron присутствует"
    else
        echo "  [WARN] ipset_update.sh в cron отсутствует"
        WARNINGS=$((WARNINGS+1))
    fi
    if grep -q 'route_watchdog.sh' "$CRON_FILE" 2>/dev/null; then
        echo "  [OK] route_watchdog.sh в cron присутствует"
    else
        echo "  [WARN] route_watchdog.sh в cron отсутствует"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] crontab admin отсутствует"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# 11. Менеджер доменов и веб-страница (v3.16)
# -----------------------------------------------------------------------------
echo "--- 11. Домены пользователя и страница ---"
if [ -x /etc/storage/bypass_domains.sh ]; then
    echo "  [OK] bypass_domains.sh на месте"
    _dc=$(grep -vcE '^[[:space:]]*(#|$)' /etc/storage/bypass_domains.lst 2>/dev/null)
    [ -z "$_dc" ] && _dc=0
    echo "  [OK] личных доменов в списке: $_dc"
else
    echo "  [WARN] bypass_domains.sh отсутствует"
    WARNINGS=$((WARNINGS+1))
fi
if [ -f /etc/storage/pwb-web/bypass.html ]; then
    echo "  [OK] страница: мастер-копия на месте"
else
    echo "  [WARN] страница не установлена"
    WARNINGS=$((WARNINGS+1))
fi
if grep -q ' /opt ' /proc/mounts 2>/dev/null; then
    if [ -f /opt/share/www/custom/index.html ]; then
        echo "  [OK] страница развёрнута: http://<router>/custom/index.html"
    else
        echo "  [WARN] /opt смонтирован, но страница не развёрнута"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo "  [WARN] /opt не смонтирован — слот /custom недоступен"
    WARNINGS=$((WARNINGS+1))
fi
if grep -qF '# >>> PWB web stage >>>' /etc/storage/started_script.sh 2>/dev/null; then
    echo "  [OK] boot-хук страницы прописан"
else
    echo "  [WARN] boot-хук страницы отсутствует — после reboot слот опустеет"
    WARNINGS=$((WARNINGS+1))
fi

# -----------------------------------------------------------------------------
# Итоги
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "                 ИТОГИ ДИАГНОСТИКИ"
echo "=============================================="
echo ""
echo "  Ошибок:    $ERRORS"
echo "  Предупреждений: $WARNINGS"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "  Система полностью исправна!"
elif [ $ERRORS -eq 0 ]; then
    echo "  Система работает, но есть незначительные предупреждения."
else
    echo "  Обнаружены критические ошибки!"
fi

if [ -n "$RECOMMENDATIONS" ]; then
    echo ""
    echo "  Рекомендации:"
    echo "$RECOMMENDATIONS"
fi

echo ""
echo "=============================================="
echo "Диагностика завершена."
EOF_DIAG
chmod +x /etc/storage/diagnostic.sh

# -----------------------------------------------------------------------------
# 2e. bypass_domains.sh — личные домены пользователя в туннель
# -----------------------------------------------------------------------------
cat > /etc/storage/bypass_domains.sh << 'EOF_BYPASSD'
#!/bin/sh
# =============================================================================
#  bypass_domains.sh — менеджер личных доменов, направляемых в туннель
#  Проект: padavan-split-routing
#  Версия 3.16.2-beta
# -----------------------------------------------------------------------------
#  Зачем: у пользователя есть сайт, которого нет ни в одном общем списке.
#  Он вводит домен в веб-странице — и домен уходит в туннель, переживая
#  перезагрузку роутера. Без SSH и без правки конфигов руками.
#
#  Использование:
#      bypass_domains.sh add <домен>     добавить домен
#      bypass_domains.sh del <домен>     удалить домен
#      bypass_domains.sh list            список доменов (по одному в строке)
#      bypass_domains.sh apply           применить список к dnsmasq + ipset
#      bypass_domains.sh status          состояние (key=value)
#      bypass_domains.sh help
#
#  Хранилище: /etc/storage/bypass_domains.lst (один домен на строку)
#
#  ВАЖНО (проверено на живом устройстве):
#   1. SIGHUP НЕ перечитывает конфиг dnsmasq — нужен ПОЛНЫЙ рестарт.
#   2. Один набор покрывает только одно семейство адресов: IPv4-адрес нельзя
#      положить в набор family inet6. Поэтому в ipset= указываются ОБА набора.
# =============================================================================

LST="/etc/storage/bypass_domains.lst"
CONF="/etc/storage/dnsmasq/dnsmasq.conf"
BEGIN="# >>> PWB bypass domains >>>"
END="# <<< PWB bypass domains <<<"
IPSET4="bypass_nets"
IPSET6="bypass_nets6"
CHUNK=30

say() { echo "$*"; }
err() { echo "ERR: $*" >&2; }

usage() {
    cat <<'USAGE'
bypass_domains.sh — личные домены в туннель

  add <домен>   добавить домен и применить сразу
  del <домен>   удалить домен и применить
  list          список доменов (по одному в строке)
  apply         пере-применить список к dnsmasq и ipset
  status        состояние: count, sets, dnsmasq
  help          эта справка

Пример: bypass_domains.sh add example.com
USAGE
}

# --- Строгая валидация домена (анти-инъекция в конфиг и shell) --------------
# Разрешены только буквы/цифры/точки/дефисы; метки не начинаются и не
# заканчиваются дефисом; минимум две метки; длина до 253.
valid_domain() {
    [ -n "$1" ] || return 1
    [ ${#1} -le 253 ] || return 1
    printf '%s' "$1" | grep -qE \
      '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

norm() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

ensure_lst() { [ -f "$LST" ] || : > "$LST"; }

# --- Полный рестарт dnsmasq (HUP не применяет конфиг!) ----------------------
restart_dnsmasq() {
    if ! pidof dnsmasq >/dev/null 2>&1; then
        return 0            # не запущен — применится при старте
    fi
    killall dnsmasq 2>/dev/null
    _i=0
    while [ -n "$(pidof dnsmasq 2>/dev/null)" ] && [ "$_i" -lt 10 ]; do
        sleep 1; _i=$((_i + 1))
    done
    if [ -n "$(pidof dnsmasq 2>/dev/null)" ]; then
        err "dnsmasq не остановился за 10 с — конфиг НЕ применён"
        return 1
    fi
    dnsmasq 2>/dev/null
    _i=0
    while [ -z "$(pidof dnsmasq 2>/dev/null)" ] && [ "$_i" -lt 10 ]; do
        sleep 1; _i=$((_i + 1))
    done
    pidof dnsmasq >/dev/null 2>&1 || { err "dnsmasq не поднялся"; return 1; }
    return 0
}

# --- Перегенерация маркерного блока (свои маркеры, чужой блок не трогаем) ---
regen_conf() {
    [ -d "$(dirname "$CONF")" ] || { err "нет каталога $(dirname "$CONF")"; return 1; }
    [ -w "$(dirname "$CONF")" ] || { err "нет записи в $(dirname "$CONF")"; return 1; }

    sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$CONF" 2>/dev/null

    ensure_lst
    _doms=$(grep -vE '^[[:space:]]*(#|$)' "$LST" 2>/dev/null)
    [ -n "$_doms" ] || return 0

    # Оба набора: IPv4 -> bypass_nets, IPv6 -> bypass_nets6 (dnsmasq разложит сам)
    printf '%s\n' "$_doms" > /tmp/pwb_dom_tmp.$$
    {
        echo "$BEGIN"
        echo "# авто-генерация bypass_domains.sh $(date '+%Y-%m-%d %H:%M') — не править вручную"
        # ВНИМАНИЕ: в POSIX sh нет local — имена переменных цикла не должны
        # совпадать с переменными вызывающей функции (был баг: пустой "OK added:").
        _acc=""; _cnt=0
        while IFS= read -r _rd; do
            [ -n "$_rd" ] || continue
            if [ -z "$_acc" ]; then _acc="$_rd"; else _acc="$_acc/$_rd"; fi
            _cnt=$((_cnt + 1))
            if [ "$_cnt" -ge "$CHUNK" ]; then
                echo "ipset=/$_acc/$IPSET4,$IPSET6"
                _acc=""; _cnt=0
            fi
        done < /tmp/pwb_dom_tmp.$$
        [ -n "$_acc" ] && echo "ipset=/$_acc/$IPSET4,$IPSET6"
        echo "$END"
    } >> "$CONF"
    rm -f /tmp/pwb_dom_tmp.$$
    return 0
}

# --- Прогреть наборы: резолв заставляет dnsmasq положить IP -----------------
warm() {
    ensure_lst
    # отдельное имя переменной — иначе затирается аргумент вызывающей ветки
    while IFS= read -r _wd; do
        case "$_wd" in ''|\#*) continue;; esac
        nslookup "$_wd" 127.0.0.1 >/dev/null 2>&1
    done < "$LST"
}

save_storage() {
    command -v mtd_storage.sh >/dev/null 2>&1 && mtd_storage.sh save >/dev/null 2>&1
    return 0
}

apply_all() {
    regen_conf || return 1
    restart_dnsmasq || return 1
    warm
    save_storage
    return 0
}

# --- Состояние набора (для status) ------------------------------------------
set_state() {
    _name="$1"
    if ipset list "$_name" >/dev/null 2>&1; then
        _c=$(ipset list "$_name" 2>/dev/null | grep -oE 'Number of entries: [0-9]+' | awk '{print $4}')
        echo "${_c:-0}"
    else
        echo "absent"
    fi
}

case "$1" in
    add)
        [ -n "$2" ] || { err "нужен домен"; exit 2; }
        _d=$(norm "$2")
        valid_domain "$_d" || { err "некорректный домен: $2"; exit 2; }
        ensure_lst
        if grep -qxF "$_d" "$LST"; then
            say "уже в списке: $_d"
        else
            printf '%s\n' "$_d" >> "$LST"
        fi
        apply_all || exit 1
        say "OK added: $_d"
        ;;
    del|delete|rm)
        [ -n "$2" ] || { err "нужен домен"; exit 2; }
        _d=$(norm "$2")
        valid_domain "$_d" || { err "некорректный домен: $2"; exit 2; }
        if [ -f "$LST" ] && grep -qxF "$_d" "$LST"; then
            grep -vxF "$_d" "$LST" > "$LST.tmp" && mv "$LST.tmp" "$LST"
            apply_all || exit 1
            say "OK removed: $_d"
        else
            say "нет в списке: $_d"
        fi
        ;;
    list|ls)
        ensure_lst
        grep -vE '^[[:space:]]*(#|$)' "$LST" 2>/dev/null
        ;;
    apply)
        apply_all || exit 1
        say "OK applied"
        ;;
    status)
        ensure_lst
        _n=$(grep -vcE '^[[:space:]]*(#|$)' "$LST" 2>/dev/null)
        [ -z "$_n" ] && _n=0
        say "count=$_n"
        say "set4=$(set_state "$IPSET4")"
        say "set6=$(set_state "$IPSET6")"
        if pidof dnsmasq >/dev/null 2>&1; then say "dnsmasq=running"; else say "dnsmasq=stopped"; fi
        if grep -qF "$BEGIN" "$CONF" 2>/dev/null; then say "block=present"; else say "block=absent"; fi
        ;;
    help|-h|--help|"")
        usage
        ;;
    *)
        err "неизвестная команда: $1"
        usage
        exit 2
        ;;
esac
EOF_BYPASSD
chmod +x /etc/storage/bypass_domains.sh

# -----------------------------------------------------------------------------
# 2f. Веб-страница «Домены в туннель» (родной слот /www/custom)
# -----------------------------------------------------------------------------
mkdir -p /etc/storage/pwb-web 2>/dev/null
cat > /etc/storage/pwb-web/bypass.html << 'EOF_BYPASSHTML'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<title>Bypass-домены</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#eef1f5;color:#1f2d3d;
     font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif}
.wrap{max-width:720px;margin:0 auto;padding:14px}
header{background:#25384d;color:#fff;border-radius:10px 10px 0 0;padding:14px 18px}
header h1{margin:0;font-size:17px;font-weight:600}
header p{margin:5px 0 0;font-size:12.5px;color:#b7c5d6}
.body{background:#fff;border:1px solid #d6dde7;border-top:0;border-radius:0 0 10px 10px;padding:16px}
.box{border:1px solid #d6dde7;border-radius:8px;padding:14px;margin-bottom:14px;background:#fbfcfe}
.desc{font-size:13px;color:#65788d;margin:0 0 12px}
.row{display:flex;gap:8px}
input[type=text]{flex:1;min-width:0;padding:11px 12px;border:1px solid #cfd8e3;
     border-radius:7px;font-size:15px;font-family:inherit}
button{cursor:pointer;border:0;border-radius:7px;padding:11px 16px;font-size:14px;
     font-weight:600;background:#2b6cb0;color:#fff;font-family:inherit}
button:disabled{opacity:.5;cursor:default}
button.ghost{background:transparent;color:#2b6cb0;border:1px solid #cfd8e3;
     font-weight:500;padding:7px 12px}
button.wide{width:100%;background:#25384d}
button.del{background:transparent;color:#c62828;border:1px solid #f0c4c4;
     padding:6px 12px;font-weight:600}
.msg{font-size:13px;margin-top:10px;min-height:19px}
.msg.ok{color:#2e7d32}.msg.err{color:#c62828}.msg.w{color:#65788d}
.listhead{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;font-weight:600}
ul.list{list-style:none;margin:0;padding:0}
li.item{display:flex;justify-content:space-between;align-items:center;gap:8px;
     padding:9px 4px;border-top:1px solid #e3e9f0}
li.item:first-child{border-top:0}
li.item code{font-size:14px;word-break:break-all}
.empty{color:#65788d;font-size:13px;padding:6px 2px}
.meta{font-size:12px;color:#65788d;margin-top:10px}
details{margin-top:6px}
summary{cursor:pointer;color:#65788d;font-size:13px}
pre{margin:8px 0 0;background:#0f1b28;color:#cfe3f5;padding:10px;border-radius:7px;
     font:12px/1.4 Consolas,monospace;white-space:pre-wrap;word-break:break-all;
     max-height:220px;overflow:auto}
.spin{display:inline-block;width:13px;height:13px;border:2px solid #cfd8e3;
     border-top-color:#2b6cb0;border-radius:50%;animation:sp .7s linear infinite;
     vertical-align:-2px;margin-right:6px}
@keyframes sp{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Домены в туннель</h1>
    <p>Сайты из этого списка пойдут через туннель — и по IPv4, и по IPv6.
       Остальной трафик идёт напрямую. Список переживает перезагрузку.</p>
  </header>
  <div class="body">

    <div class="box">
      <p class="desc">Добавьте сайт, который не открывается напрямую
        (например <code>example.com</code>).</p>
      <div class="row">
        <input id="dom" type="text" placeholder="example.com" autocomplete="off"
               autocapitalize="off" autocorrect="off" spellcheck="false"
               onkeydown="if(event.key==='Enter')addDomain()">
        <button id="addBtn" onclick="addDomain()">Добавить</button>
      </div>
      <div id="msg" class="msg"></div>
    </div>

    <div class="box">
      <div class="listhead">
        <span>Список</span>
        <button class="ghost" id="refBtn" onclick="refresh()">Обновить</button>
      </div>
      <ul id="list" class="list"><li class="empty">загрузка…</li></ul>
      <div class="meta" id="meta"></div>
    </div>

    <div class="box">
      <button class="wide" id="applyBtn" onclick="applyAll()">Применить заново</button>
      <p class="desc" style="margin:10px 0 0">Обычно не нужно: добавление и удаление
        применяются сразу.</p>
    </div>

    <details>
      <summary>Журнал последней операции</summary>
      <pre id="log">—</pre>
    </details>

  </div>
</div>

<script>
/* v3.16.2
   Команды выполняются штатным механизмом прошивки — тем же, что у страницы
   «Консоль»: POST /apply.cgi с action_mode=' SystemCmd ', вывод — из
   /console_response.asp. Права те же, что у WebUI (нужен вход в веб-интерфейс). */
var SCRIPT = '/etc/storage/bypass_domains.sh';
var busy = false;

function $(id){ return document.getElementById(id); }
function setMsg(t, cls){ var m=$('msg'); m.className='msg '+(cls||''); m.innerHTML=t; }
function setLog(t){ $('log').textContent = t || '—'; }

/* Проверка для быстрой обратной связи. Настоящая валидация — в скрипте
   на роутере: JS не является защитой, его легко обойти. */
function looksLikeDomain(d){
  return d.length >= 3 && d.length <= 253 &&
         /^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])$/.test(d) &&
         d.indexOf('..') === -1 && d.indexOf('.') > 0;
}

function run(args){
  var body = 'action_mode=' + encodeURIComponent(' SystemCmd ')
           + '&current_page=' + encodeURIComponent('console_response.asp')
           + '&next_page=' + encodeURIComponent('console_response.asp')
           + '&SystemCmd=' + encodeURIComponent('sh ' + SCRIPT + ' ' + args);
  return fetch('/apply.cgi', {
      method:'POST', credentials:'same-origin',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body: body
    })
    .then(function(){
      // v3.16.2: console_response.asp нельзя брать из кэша — иначе после
      // удаления рисуется устаревший список, хотя на роутере он уже пуст.
      return fetch('/console_response.asp?_t=' + Date.now(),
                   {credentials:'same-origin', cache:'no-store'});
    })
    .then(function(r){ return r.text(); });
}

function lock(on){
  busy = on;
  $('addBtn').disabled = on;
  $('applyBtn').disabled = on;
  $('refBtn').disabled = on;
}

function parseList(out){
  return out.split(/\r?\n/)
    .map(function(s){ return s.trim(); })
    .filter(function(s){
      return /^[a-z0-9]([a-z0-9.-]*[a-z0-9])$/.test(s) && s.indexOf('.') > 0;
    });
}

function parseStatus(out){
  var o = {};
  out.split(/\r?\n/).forEach(function(line){
    var m = line.match(/^([a-z0-9_]+)=(.*)$/);
    if(m) o[m[1]] = m[2].trim();
  });
  return o;
}

var current = [];

function render(domains){
  current = domains.slice();
  var ul = $('list');
  ul.innerHTML = '';
  if(!domains.length){
    ul.innerHTML = '<li class="empty">Список пуст</li>';
    return;
  }
  domains.forEach(function(d){
    var li = document.createElement('li'); li.className = 'item';
    var c = document.createElement('code'); c.textContent = d;
    var b = document.createElement('button');
    b.className = 'del'; b.textContent = 'Удалить';
    b.onclick = function(){ delDomain(d); };
    li.appendChild(c); li.appendChild(b);
    ul.appendChild(li);
  });
}

function showMeta(st){
  var parts = [];
  if(st.set4 !== undefined) parts.push('IPv4-набор: ' + st.set4);
  if(st.set6 !== undefined) parts.push('IPv6-набор: ' + st.set6);
  if(st.dnsmasq) parts.push(st.dnsmasq === 'running' ? 'dnsmasq работает' : 'dnsmasq остановлен');
  $('meta').textContent = parts.join(' · ');
}

function reload(){
  return run('list').then(function(out){
    setLog(out); render(parseList(out));
    return run('status').then(function(st){
      showMeta(parseStatus(st));
      return st;
    });
  });
}

function refresh(){
  if(busy) return;
  lock(true); setMsg('<span class="spin"></span>обновление…','w');
  reload()
    .then(function(){ setMsg('',''); })
    .catch(function(e){ setMsg('Ошибка связи: ' + e, 'err'); })
    .then(function(){ lock(false); });
}

function addDomain(){
  if(busy) return;
  var inp = $('dom');
  var d = (inp.value || '').trim().toLowerCase()
            .replace(/^https?:\/\//,'').replace(/\/.*$/,'').replace(/\.$/,'');
  if(!looksLikeDomain(d)){ setMsg('Некорректный домен. Пример: example.com','err'); return; }

  lock(true); setMsg('<span class="spin"></span>добавляю ' + d + '…','w');
  run('add ' + d)
    .then(function(out){
      setLog(out);
      if(/^ERR:/m.test(out)) throw new Error(out.split('\n')[0].replace(/^ERR:\s*/,''));
      inp.value = '';
      setMsg('Готово: ' + d + '. Проверьте сайт через 10–20 секунд.','ok');
      return reload();
    })
    .catch(function(e){ setMsg('Не удалось: ' + e, 'err'); })
    .then(function(){ lock(false); });
}

function delDomain(d){
  if(busy) return;
  lock(true); setMsg('<span class="spin"></span>удаляю ' + d + '…','w');
  run('del ' + d)
    .then(function(out){
      setLog(out);
      if(/^ERR:/m.test(out)) throw new Error(out.split('\n')[0].replace(/^ERR:\s*/,''));
      // v3.16.2: убираем из DOM сразу — интерфейс не должен ждать/зависеть от кэша
      var left = current.filter(function(x){ return x !== d; });
      render(left);
      setMsg('Удалён: ' + d + ' — сайт снова идёт напрямую.','ok');
      return reload();
    })
    .catch(function(e){ setMsg('Не удалось: ' + e, 'err'); })
    .then(function(){ lock(false); });
}

function applyAll(){
  if(busy) return;
  lock(true); setMsg('<span class="spin"></span>применяю…','w');
  run('apply')
    .then(function(out){
      setLog(out);
      if(/^ERR:/m.test(out)) throw new Error(out.split('\n')[0].replace(/^ERR:\s*/,''));
      setMsg('Список применён.','ok');
      return reload();
    })
    .catch(function(e){ setMsg('Не удалось: ' + e, 'err'); })
    .then(function(){ lock(false); });
}

document.addEventListener('DOMContentLoaded', refresh);
</script>
</body>
</html>
EOF_BYPASSHTML

cat > /etc/storage/pwb_web_setup.sh << 'EOF_PWBWEB'
#!/bin/sh
# =============================================================================
#  pwb_web_setup.sh — разворачивает страницу «Домены в туннель» в WebUI
#  Версия 3.16.2-beta
# -----------------------------------------------------------------------------
#  /www — read-only squashfs, но прошивка уже содержит симлинк
#  /www/custom -> /opt/share/www/custom. /opt пуст и тоже read-only, однако
#  mount разрешён: tmpfs поверх /opt оживляет симлинк.
#
#  ВАЖНО: /opt — tmpfs, при перезагрузке всё теряется. Boot-хук обязан
#  монтировать tmpfs ЗАНОВО, а не только копировать файл.
#
#  Использование: pwb_web_setup.sh stage | unstage | status
# =============================================================================

WEB_DIR="/etc/storage/pwb-web"
PAGE_SRC="$WEB_DIR/bypass.html"
CUSTOM_DIR="/opt/share/www/custom"
BOOT_SCRIPT="/etc/storage/started_script.sh"
MB="# >>> PWB web stage >>>"
ME="# <<< PWB web stage <<<"

say() { echo "$*"; }
err() { echo "ERR: $*" >&2; }

# tmpfs считается поднятым, если он виден в /proc/mounts ИЛИ /opt стал
# доступен на запись (на части прошивок строка монтирования отличается).
opt_mounted() {
    grep -q ' /opt ' /proc/mounts 2>/dev/null && return 0
    [ -w /opt ] && return 0
    return 1
}

stage() {
    [ -f "$PAGE_SRC" ] || { err "нет страницы $PAGE_SRC"; return 1; }

    if ! opt_mounted; then
        mount -t tmpfs -o size=8m tmpfs /opt 2>/dev/null
    fi
    if ! opt_mounted; then
        err "не удалось смонтировать tmpfs на /opt — слот /custom недоступен"
        return 1
    fi

    mkdir -p "$CUSTOM_DIR" 2>/dev/null || { err "не создался $CUSTOM_DIR"; return 1; }
    cp -f "$PAGE_SRC" "$CUSTOM_DIR/index.html" || { err "не скопировалась страница"; return 1; }
    sync
    say "OK staged: http://<router>/custom/index.html"
    return 0
}

install_boot_hook() {
    [ -f "$BOOT_SCRIPT" ] || { say "boot-хук: нет $BOOT_SCRIPT — пропуск"; return 0; }
    sed -i "\|^$MB\$|,\|^$ME\$|d" "$BOOT_SCRIPT" 2>/dev/null
    {
        echo "$MB"
        echo "# tmpfs на /opt теряется при reboot — монтировать заново перед копированием"
        echo "grep -q ' /opt ' /proc/mounts 2>/dev/null || mount -t tmpfs -o size=8m tmpfs /opt 2>/dev/null"
        echo "mkdir -p $CUSTOM_DIR 2>/dev/null"
        echo "cp -f $PAGE_SRC $CUSTOM_DIR/index.html 2>/dev/null"
        echo "$ME"
    } >> "$BOOT_SCRIPT"
    say "OK boot-hook обновлён"
    return 0
}

remove_boot_hook() {
    [ -f "$BOOT_SCRIPT" ] || return 0
    sed -i "\|^$MB\$|,\|^$ME\$|d" "$BOOT_SCRIPT" 2>/dev/null
    say "OK boot-hook снят"
    return 0
}

unstage() {
    rm -f "$CUSTOM_DIR/index.html" 2>/dev/null
    rmdir "$CUSTOM_DIR" 2>/dev/null
    remove_boot_hook
    say "OK unstage"
    return 0
}

status() {
    [ -f "$PAGE_SRC" ] && say "page=present" || say "page=absent"
    opt_mounted && say "opt=tmpfs" || say "opt=ro"
    [ -f "$CUSTOM_DIR/index.html" ] && say "runtime=present" || say "runtime=absent"
    grep -qF "$MB" "$BOOT_SCRIPT" 2>/dev/null && say "boothook=present" || say "boothook=absent"
    return 0
}

case "$1" in
    stage)   stage && install_boot_hook ;;
    unstage) unstage ;;
    status)  status ;;
    *) echo "usage: $0 stage|unstage|status"; exit 2 ;;
esac
EOF_PWBWEB
chmod +x /etc/storage/pwb_web_setup.sh

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
# v3.15.3: ip6_set_hash_net не существует

( sleep 60 && sh /etc/storage/ipset_update.sh ) &
( sleep 90 && /etc/storage/route_watchdog.sh & ) &

# >>> PWB web stage >>>
# /opt — tmpfs: после перезагрузки снова read-only и симлинк /www/custom
# висит в пустоту. Поэтому tmpfs монтируется ЗАНОВО, а не только копируется файл.
grep -q ' /opt ' /proc/mounts 2>/dev/null || mount -t tmpfs -o size=8m tmpfs /opt 2>/dev/null
mkdir -p /opt/share/www/custom 2>/dev/null
cp -f /etc/storage/pwb-web/bypass.html /opt/share/www/custom/index.html 2>/dev/null
# <<< PWB web stage <<<
EOF_STARTED

chmod +x /etc/storage/started_script.sh

# v3.16.1: развернуть страницу СРАЗУ, не дожидаясь перезагрузки.
# Без этого /opt остаётся read-only, каталог custom не создан, симлинк
# /www/custom висит в пустоту и страница отдаётся пустой.
# Вызов строго ПОСЛЕ создания started_script.sh — иначе boot-хук некуда писать.
if [ -x /etc/storage/pwb_web_setup.sh ]; then
    /etc/storage/pwb_web_setup.sh stage || \
        echo "  [WARN] страница не развёрнута сейчас — сработает при загрузке"
fi

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

echo ""
echo "=============================================="
echo "Установка v3.16.2-beta завершена. Запускаю первый импорт..."
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
