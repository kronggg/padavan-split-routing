#!/bin/sh
# =============================================================================
#  pwb_web_setup.sh — разворачивает страницу «Домены в туннель» в WebUI
#  Версия 3.16.4
# -----------------------------------------------------------------------------
#  /www — read-only squashfs, но прошивка уже содержит симлинк
#  /www/custom -> /opt/share/www/custom. /opt пуст и тоже read-only, однако
#  mount разрешён: tmpfs поверх /opt оживляет симлинк.
#
#  ВАЖНО: /opt — tmpfs, при перезагрузке всё теряется. Boot-хук обязан
#  монтировать tmpfs ЗАНОВО, а не только копировать файл.
#
#  Использование: pwb_web_setup.sh stage | ensure | unstage | status
#
#  ВАЖНО (v3.16.4): раньше все ошибки mount/cp глушились через 2>/dev/null,
#  поэтому неудача выглядела как успех, а страница отдавалась пустой.
#  Теперь причина печатается, делается повтор, и результат проверяется.
# =============================================================================

WEB_DIR="/etc/storage/pwb-web"
PAGE_SRC="$WEB_DIR/bypass.html"
CUSTOM_DIR="/opt/share/www/custom"
RUNTIME_FILE="$CUSTOM_DIR/index.html"
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

# Поднять tmpfs. Возврат: 0 — смонтирован, 1 — нет (причина в $_mount_err).
mount_opt() {
    opt_mounted && return 0

    # /opt может отсутствовать в образе — без каталога mount не сработает
    [ -d /opt ] || mkdir -p /opt 2>/dev/null

    _mount_err=$(mount -t tmpfs -o size=8m tmpfs /opt 2>&1)
    opt_mounted && { _mount_err=""; return 0; }

    # одна повторная попытка: на части прошивок первый mount отваливается,
    # пока не завершится инициализация хранилища
    sleep 1
    _mount_err2=$(mount -t tmpfs -o size=8m tmpfs /opt 2>&1)
    opt_mounted && { _mount_err=""; return 0; }

    [ -n "$_mount_err2" ] && _mount_err="$_mount_err2"
    [ -z "$_mount_err" ] && _mount_err="mount вернул успех, но /opt не виден в /proc/mounts и не доступен на запись"
    return 1
}

stage() {
    [ -f "$PAGE_SRC" ] || { err "нет мастер-копии страницы: $PAGE_SRC"; return 1; }
    [ -s "$PAGE_SRC" ] || { err "мастер-копия страницы пуста: $PAGE_SRC"; return 1; }

    if ! opt_mounted; then
        if ! mount_opt; then
            err "не удалось смонтировать tmpfs на /opt: $_mount_err"
            return 1
        fi
    fi

    mkdir -p "$CUSTOM_DIR" 2>/dev/null || { err "не создался каталог $CUSTOM_DIR"; return 1; }

    _cp_err=$(cp -f "$PAGE_SRC" "$RUNTIME_FILE" 2>&1)
    if [ ! -f "$RUNTIME_FILE" ]; then
        err "страница не скопирована в $RUNTIME_FILE${_cp_err:+: $_cp_err}"
        return 1
    fi
    if [ ! -s "$RUNTIME_FILE" ]; then
        err "скопированная страница пуста: $RUNTIME_FILE"
        return 1
    fi

    sync 2>/dev/null
    say "OK staged: http://<router>/custom/index.html"
    return 0
}

install_boot_hook() {
    [ -f "$BOOT_SCRIPT" ] || { say "boot-хук: нет $BOOT_SCRIPT — пропуск"; return 0; }
    sed -i "\|^$MB\$|,\|^$ME\$|d" "$BOOT_SCRIPT" 2>/dev/null
    {
        echo "$MB"
        echo "# tmpfs на /opt теряется при reboot — монтировать заново перед копированием."
        echo "# Повтор и проверка: без них сбой mount оставлял слот пустым без следов."
        echo "[ -d /opt ] || mkdir -p /opt 2>/dev/null"
        echo "grep -q ' /opt ' /proc/mounts 2>/dev/null || mount -t tmpfs -o size=8m tmpfs /opt 2>/dev/null"
        echo "grep -q ' /opt ' /proc/mounts 2>/dev/null || { sleep 1; mount -t tmpfs -o size=8m tmpfs /opt 2>/dev/null; }"
        echo "mkdir -p $CUSTOM_DIR 2>/dev/null"
        echo "cp -f $PAGE_SRC $RUNTIME_FILE 2>/dev/null"
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
    rm -f "$RUNTIME_FILE" 2>/dev/null
    rmdir "$CUSTOM_DIR" 2>/dev/null
    remove_boot_hook
    say "OK unstage"
    return 0
}

status() {
    [ -f "$PAGE_SRC" ] && say "page=present" || say "page=absent"
    opt_mounted && say "opt=tmpfs" || say "opt=ro"
    [ -s "$RUNTIME_FILE" ] && say "runtime=present" || say "runtime=absent"
    grep -qF "$MB" "$BOOT_SCRIPT" 2>/dev/null && say "boothook=present" || say "boothook=absent"
    return 0
}

# ensure — развернуть и подтвердить итог (используется установщиком).
# Возврат 0 только если слот реально живой: tmpfs поднят и файл непустой.
ensure() {
    _st=0
    stage || _st=1
    install_boot_hook
    if [ "$_st" -eq 0 ] && opt_mounted && [ -s "$RUNTIME_FILE" ]; then
        return 0
    fi
    err "слот не подтверждён после stage: $(status | tr '\n' ' ')"
    return 1
}

case "$1" in
    stage)   stage && install_boot_hook ;;
    ensure)  ensure ;;
    unstage) unstage ;;
    status)  status ;;
    *) echo "usage: $0 stage|ensure|unstage|status"; exit 2 ;;
esac
