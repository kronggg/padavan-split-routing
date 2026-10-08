#!/bin/sh
# Функциональный тест restore_learned: OLD (сломанный) vs NEW (фикс).
# Демонстрирует баг-класс, который shellcheck/sh -n НЕ ловят.
IPSET_NAME=bypass_nets

ipset() { [ "$1" = "add" ] && echo "    ipset add $2"; return 0; }
log()   { echo "    LOG: $*"; }

restore_old() {
    [ -f "$LEARNED_CACHE" ] || return 0
    count=0
    while read ip; do
        [ -z "$ip" ] && continue
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && count=$((count+1))
    done < "$(sort -u "$LEARNED_CACHE")"
    log "OLD restored=$count"
}

restore_new() {
    [ -f "$LEARNED_CACHE" ] || return 0
    count=0
    sort -u "$LEARNED_CACHE" > "$LEARNED_CACHE.dedup" 2>/dev/null
    if [ ! -s "$LEARNED_CACHE.dedup" ]; then
        rm -f "$LEARNED_CACHE.dedup"; log "NEW restored=0"; return 0
    fi
    while read ip; do
        [ -z "$ip" ] && continue
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null && count=$((count+1))
    done < "$LEARNED_CACHE.dedup"
    rm -f "$LEARNED_CACHE.dedup"
    log "NEW restored=$count"
}

D=$(dirname "$0"); CACHE="$D/test-learned.cache"
printf '213.180.204.127\n8.209.7.101\n213.180.204.127\n' > "$CACHE"
echo "cache (3 строки, 1 дубль):"; sed 's/^/  /' "$CACHE"
echo "--- OLD (broken: done < \"\$(sort ...)\") ---"; LEARNED_CACHE="$CACHE"; restore_old
echo "--- NEW (fixed: dedup -> temp file) ---"; LEARNED_CACHE="$CACHE"; restore_new
rm -f "$CACHE"
