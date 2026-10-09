#!/bin/sh
# =============================================================================
#  restore_test.sh (v3.13) — функциональный тест преобразования доменного
#  блок-листа itdoginfo → строк dnsmasq для ipset bypass_nets.
#
#  Раньше (v3.12) этот файл тестировал функцию восстановления выученных IP —
#  она УДАЛЕНА вместе с механизмом автообучения. Теперь проверяем новый механизм.
#
#  Использование:  sh restore_test.sh   (на ПК; требует сети) или
#                  make test           (встроено в харнесс)
# =============================================================================

URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-ipset.lst"
RAW="/tmp/pwb_dm.raw"
OUT="/tmp/pwb_dm.ipset"

fail=0
ok()   { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }

echo "=== dnsmasq-blocklist transform test (v3.13) ==="

wget -q -O "$RAW" "$URL" 2>/dev/null
if [ ! -s "$RAW" ]; then
    echo "  [SKIP] нет сети / пустой ответ — пропуск"
    exit 0
fi

# Трансформация: vpn_domains -> bypass_nets, только ipset=-строки
grep '^ipset=/' "$RAW" | sed 's|/vpn_domains$|/bypass_nets|' > "$OUT"

n=$(wc -l < "$OUT")
junk=$(grep -vc '^ipset=/.*/bypass_nets$' "$OUT" 2>/dev/null || echo 0)

if [ "$n" -gt 100 ]; then ok "строк: $n (>100)"; else bad "мало строк: $n"; fi
if [ "$junk" -eq 0 ]; then ok "мусорных строк: 0"; else bad "мусор: $junk"; fi

# Все строки должны заканчиваться на /bypass_nets
if grep -q '/vpn_domains' "$OUT"; then bad "остались vpn_domains"; else ok "vpn_domains не осталось"; fi

rm -f "$RAW" "$OUT"
echo "=== ИТОГ: FAIL=$fail ==="
[ "$fail" -eq 0 ] || exit 1
exit 0
