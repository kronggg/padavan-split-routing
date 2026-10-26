#!/bin/sh
# Регресс: переменные, используемые во встроенных heredoc, должны быть
# определены ВНУТРИ этих heredoc (кавычки << 'EOF' блокируют подстановку).
# Реальный дефект 3.15.3: встроенная диагностика печатала
# "[FAIL] IPv6-набор  отсутствует" — $IPSET6_NAME был пуст.
set -u
f=install.sh
fail=0

check_one() {
    name="$1"; endmark="$2"
    tmp="/tmp/_hv_${name}"
    awk -v pref="cat > /etc/storage/${name}" -v e="$endmark" '
        index($0, pref) == 1 { f=1; next }
        f && $0 == e { f=0 }
        f { print }
    ' "$f" > "$tmp" || { echo "  [FAIL] awk error for $name"; return 1; }

    [ -s "$tmp" ] || { echo "  [FAIL] $name: heredoc не найден"; return 1; }

    for v in IPSET_NAME IPSET6_NAME; do
        if grep -q "\$$v" "$tmp" 2>/dev/null; then
            if ! grep -q "^${v}=" "$tmp"; then
                echo "  [FAIL] embedded $name: \$$v используется, но не определён в heredoc"
                return 1
            fi
        fi
    done
    echo "  [OK] embedded $name: переменные определены"
    return 0
}

check_one diagnostic.sh EOF_DIAG || fail=1
check_one selftest.sh EOF_SELFTEST || fail=1
exit $fail
