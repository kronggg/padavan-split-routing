#!/bin/sh
# =============================================================================
#  pwb_web_setup.sh — разворачивает страницу «Домены в туннель» в WebUI
#  Версия 3.16.3-beta
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
