#!/bin/sh
# Регресс: встроенные в install.sh копии скриптов должны совпадать с
# отдельными файлами в репозитории. Дефект уже дважды случался: правишь
# отдельный файл, забываешь про heredoc — установка кладёт старое.
set -u
fail=0

check_sync() {
    name="$1"; start="$2"; end="$3"; src="$4"
    tmp="/tmp/_sync_$$_$(echo "$name" | tr '/.' '__')"
    awk -v p="$start" -v en="$end" 'index($0,p)==1{f=1;next} f&&$0==en{f=0} f' install.sh > "$tmp"
    if [ ! -s "$tmp" ]; then
        echo "  [FAIL] $name: встроенная копия не найдена"
        rm -f "$tmp"; return 1
    fi
    if diff -q "$src" "$tmp" >/dev/null 2>&1; then
        echo "  [OK] $name синхронизирован"
        rm -f "$tmp"; return 0
    fi
    echo "  [FAIL] $name: встроенная копия расходится с $src"
    diff "$src" "$tmp" | head -6
    rm -f "$tmp"
    return 1
}

check_sync "selftest.sh"      "cat > /etc/storage/selftest.sh"        "EOF_SELFTEST"    "selftest.sh"        || fail=1
check_sync "diagnostic.sh"    "cat > /etc/storage/diagnostic.sh"      "EOF_DIAG"        "diagnostic.sh"      || fail=1
check_sync "bypass_domains.sh" "cat > /etc/storage/bypass_domains.sh" "EOF_BYPASSD"     "bypass_domains.sh"  || fail=1
check_sync "web/bypass.html"  "cat > /etc/storage/pwb-web/bypass.html" "EOF_BYPASSHTML" "web/bypass.html"   || fail=1

exit $fail
