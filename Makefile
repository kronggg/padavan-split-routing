# Makefile — проверки проекта padavan-split-routing
# make test      — полная проверка
# make syntax    — только синтаксис
# make version   — сверка версий

SHELL := /bin/sh
SCRIPTS := install.sh uninstall.sh diagnostic.sh selftest.sh rollback.sh hardware_check.sh bypass_domains.sh pwb_web_setup.sh

.PHONY: all test syntax embedded hup-clean ipv6 webstage sync version-sync version

all: test

syntax:
	@echo "=== [1/5] syntax: busybox sh -n ==="
	@fail=0; \
	for f in $(SCRIPTS); do \
	    if [ -f "$$f" ]; then \
	        if busybox sh -n "$$f" 2>/dev/null; then echo "  [OK] $$f"; \
	        else echo "  [FAIL] $$f"; fail=1; fi; \
	    fi; \
	done; \
	exit $$fail

embedded:
	@echo "=== [2/5] embedded heredocs ==="
	@fail=0; \
	for pair in "rollback.sh:EOF_ROLLBACK" "selftest.sh:EOF_SELFTEST" "ipset_update.sh:EOF_SCRIPT" "route_watchdog.sh:EOF_WATCHDOG" "started_script.sh:EOF_STARTED" "diagnostic.sh:EOF_DIAG"; do \
	    n=$${pair%%:*}; e=$${pair##*:}; \
	    awk "/^cat > \/etc\/storage\/$$n/{f=1;next} /^$$e/{f=0} f" install.sh > /tmp/_mk_$$n 2>/dev/null; \
	    if [ -s /tmp/_mk_$$n ]; then \
	        if busybox sh -n /tmp/_mk_$$n 2>/dev/null; then echo "  [OK] embedded $$n"; \
	        else echo "  [FAIL] embedded $$n"; fail=1; fi; \
	    fi; \
	done; \
	exit $$fail

hup-clean:
	@echo "=== [3/5] regression: no killall -HUP dnsmasq ==="
	@if grep -rn 'killall -HUP dnsmasq' $(SCRIPTS) 2>/dev/null; then \
	    echo "  [FAIL] найден killall -HUP dnsmasq — конфиг НЕ применится"; exit 1; \
	else echo "  [OK] HUP для dnsmasq отсутствует"; fi

ipv6:
	@echo "=== regression: IPv6 (dual set) ==="
	@grep -q 'IPSET_NAME},\$${IPSET6_NAME}' install.sh || { echo "  [FAIL] генерация ipset= без второго набора"; exit 1; }
	@echo "  [OK] генерация использует два набора"
	@if grep -v '^[[:space:]]*#' install.sh diagnostic.sh 2>/dev/null | grep -q 'ip6_set_hash_net'; then echo "  [FAIL] используется несуществующий модуль ip6_set_hash_net"; exit 1; fi
	@echo "  [OK] несуществующий модуль не используется"
	@grep -q 'ensure\|ipset list "\$$IPSET6_NAME" >/dev/null' install.sh || { echo "  [FAIL] нет гарантии существования наборов"; exit 1; }
	@echo "  [OK] наборы создаются до рестарта"
	@if grep -q 'можно игнорировать' install.sh diagnostic.sh 2>/dev/null; then echo "  [FAIL] остался текст 'можно игнорировать'"; exit 1; fi
	@echo "  [OK] ложного совета нет"
	@sh ./scripts/check-heredoc-vars.sh || exit 1
	@echo "  [OK] переменные определены внутри встроенных копий"

webstage:
	@echo "=== regression: web page staged at install time ==="
	@grep -q 'pwb_web_setup.sh stage' install.sh || { echo "  [FAIL] install.sh не вызывает stage — страница останется пустой"; exit 1; }
	@echo "  [OK] stage вызывается при установке"
	@if [ -f pwb_web_setup.sh ]; then \
	    a=$$(grep -n 'chmod +x /etc/storage/started_script.sh' install.sh | cut -d: -f1); \
	    b=$$(grep -n '^    /etc/storage/pwb_web_setup.sh stage' install.sh | cut -d: -f1); \
	    if [ -z "$$a" ] || [ -z "$$b" ]; then echo "  [FAIL] не найдены якоря порядка"; exit 1; fi; \
	    if [ "$$b" -lt "$$a" ]; then echo "  [FAIL] stage вызывается ДО создания started_script.sh (boot-хук некуда писать)"; exit 1; fi; \
	    echo "  [OK] порядок верный: stage после started_script ($$b > $$a)"; \
	fi
	@grep -q "grep -q ' /opt ' /proc/mounts" install.sh || { echo "  [FAIL] нет проверки монтирования /opt"; exit 1; }
	@echo "  [OK] проверка монтирования /opt присутствует"

sync:
	@echo "=== regression: heredoc copies match standalone files ==="
	@sh ./scripts/check-heredoc-sync.sh || exit 1

version-sync:
	@echo "=== [4/5] version consistency ==="
	@v=$$(cat VERSION 2>/dev/null | tr -d '[:space:]'); \
	echo "  VERSION: $$v"; \
	fail=0; \
	for f in install.sh diagnostic.sh; do \
	    [ -f "$$f" ] || continue; \
	    if grep -q "v$$v" "$$f"; then echo "  [OK] $$f печатает v$$v"; \
	    else echo "  [FAIL] $$f не содержит v$$v"; fail=1; fi; \
	done; \
	exit $$fail

version: version-sync

test: syntax embedded hup-clean ipv6 webstage sync version-sync
	@echo ""
	@echo "=== [5/5] structural checks ==="
	@grep -q '# >>> PWB dnsmasq ipset >>>' install.sh || { echo "  [FAIL] нет открывающего маркера"; exit 1; }
	@grep -q '# <<< PWB dnsmasq ipset <<<' install.sh || { echo "  [FAIL] нет закрывающего маркера"; exit 1; }
	@echo "  [OK] маркеры блока на месте"
	@grep -q 'pidof dnsmasq' install.sh || { echo "  [FAIL] нет проверки pidof dnsmasq"; exit 1; }
	@echo "  [OK] проверка готовности dnsmasq присутствует"
	@if grep -q 'print [$]3' install.sh selftest.sh diagnostic.sh 2>/dev/null; then echo "  [FAIL] старый парсер (3-е поле)"; exit 1; fi
	@echo "  [OK] парсер IP использует 2-е поле"
	@echo ""
	@echo "=== ALL TESTS PASSED ==="
