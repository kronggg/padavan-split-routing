#!/bin/sh
# =============================================================================
#  bypass_domains.sh — менеджер личных доменов, направляемых в туннель
#  Проект: padavan-split-routing
#  Версия 3.16.4
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
            # v3.16.3: grep -v возвращает 1, когда строк НЕ осталось. Из-за
            # `&& mv` удаление ПОСЛЕДНЕГО домена молча не применялось: файл
            # оставался прежним, а «OK removed» печаталось. Разделяем код
            # возврата и замену файла: 0 и 1 — успех (есть/нет строк),
            # 2+ — настоящая ошибка.
            grep -vxF "$_d" "$LST" > "$LST.tmp"
            _rc=$?
            if [ "$_rc" -le 1 ]; then
                mv -f "$LST.tmp" "$LST" || { err "не удалось обновить $LST"; rm -f "$LST.tmp"; exit 1; }
            else
                err "ошибка чтения $LST (grep rc=$_rc)"
                rm -f "$LST.tmp"
                exit 1
            fi
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
