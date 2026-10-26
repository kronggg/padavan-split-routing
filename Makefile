# Makefile — проверки проекта padavan-split-routing
# make test      — полная проверка
# make syntax    — только синтаксис
# make version   — сверка версий

SHELL := /bin/sh
SCRIPTS := install.sh uninstall.sh diagnostic.sh selftest.sh rollback.sh hardware_check.sh

.PHONY: all test syntax embedded hup-clean version-sync version

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

test: syntax embedded hup-clean version-sync
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
