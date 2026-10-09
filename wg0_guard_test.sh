#!/bin/sh
# Функциональный тест wg0-guard в watchdog (отражает продакшн-логику 1:1).
# Проверяет, что stderr ЧИСТ во всех состояниях wg0 (нет "Cannot find device wg0",
# нет "can't create .../rp_filter").
LOG=/tmp/wg0_test.log
WG0_WAIT_LOGGED=0
RP_PATH=/tmp/rp_missing/proc/sys/net/ipv4/conf/wg0/rp_filter   # дефолт: путь отсутствует

ip() {
    case "$1 $2" in
        "link show") [ "${WG0_PRESENT:-0}" = "1" ] && return 0 || return 1 ;;
        "route show") [ "${ROUTE_SET:-0}" = "1" ] && echo "default dev wg0" || true ;;
        "route replace") echo "REPLACE-CALLED default dev wg0 table 51" ;;
    esac
}
sysctl() { [ "${RP:-1}" = "0" ] && echo 0 || echo 1; }

run_once() {
    if ! ip link show wg0 >/dev/null 2>&1; then
        if [ "$WG0_WAIT_LOGGED" != "1" ]; then
            WG0_WAIT_LOGGED=1
            echo "[date] Watchdog: wg0 ещё не поднят — маршрут/rp_filter пропущены" >> "$LOG"
        fi
    else
        WG0_WAIT_LOGGED=0
        if ! ip route show table 51 | grep -q "default dev wg0"; then
            ip route replace default dev wg0 table 51 2>/dev/null
            echo "[date] Watchdog: исправлен маршрут в table 51" >> "$LOG"
        fi
        if [ "$(sysctl -n net.ipv4.conf.wg0.rp_filter 2>/dev/null)" != "0" ]; then
            if [ -f "$RP_PATH" ]; then
                echo 0 > "$RP_PATH" 2>/dev/null
                echo "[date] Watchdog: исправлен rp_filter" >> "$LOG"
            fi
        fi
    fi
}

chk() { # $1=label $2=got $3=want
    if [ "$2" = "$3" ]; then echo "  [OK]   $1 = [$2]"; else echo "  [FAIL] $1 = [$2] (ожидалось [$3])"; fi
}

echo "### CASE 1: wg0 ОТСУТСТВУЕТ (2 итерации) ###"
: > "$LOG"; WG0_PRESENT=0
ERR1=$( { run_once; run_once; } 2>&1 >/dev/null )
chk "stderr пуст" "$ERR1" ""
chk "лог-строк 'не поднят'" "$(grep -c 'не поднят' "$LOG")" "1"

echo "### CASE 2: wg0 ЕСТЬ, маршрут нет, rp_filter=1, путь /proc ЕСТЬ ###"
: > "$LOG"; WG0_PRESENT=1; ROUTE_SET=0; RP=1
mkdir -p "$(dirname "$RP_PATH")"; : > "$RP_PATH"
ERR2=$(run_once 2>&1 >/dev/null)
chk "stderr пуст" "$ERR2" ""
chk "лог 'исправлен маршрут'" "$(grep -c 'исправлен маршрут' "$LOG")" "1"
chk "rp_filter записан" "$(cat "$RP_PATH")" "0"

echo "### CASE 3: wg0 ЕСТЬ, но путь /proc/.../wg0 ОТСУТСТВУЕТ (edge) ###"
: > "$LOG"; WG0_PRESENT=1; ROUTE_SET=1; RP=1; RP_PATH=/tmp/rp_missing/proc/.../wg0/rp_filter
ERR3=$(run_once 2>&1 >/dev/null)
chk "stderr пуст (нет can't create)" "$ERR3" ""

echo "### CASE 4: wg0 ЕСТЬ, всё настроено (rp_filter=0) ###"
: > "$LOG"; WG0_PRESENT=1; ROUTE_SET=1; RP=0
run_once 2>/dev/null
chk "лог-строк" "$(wc -l < "$LOG")" "0"

rm -f "$LOG"; rm -rf /tmp/rp_missing
