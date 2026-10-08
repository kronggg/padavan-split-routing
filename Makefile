# padavan-warp-bypass — test harness (POSIX/BusyBox sh)
SHELL := /bin/sh
SH := busybox sh
TMP := ./.build-test

.PHONY: test syntax extract func consistency
test: syntax extract func consistency
	@echo "=== ALL TESTS PASSED ==="

syntax:
	@echo "=== [1/4] syntax standalone ==="
	@for f in install.sh uninstall.sh diagnostic.sh rollback.sh selftest.sh restore_test.sh; do \
		$(SH) -n "$$f" && echo "  [OK] $$f" || { echo "  [FAIL] $$f"; exit 1; }; done

extract:
	@echo "=== [2/4] heredoc extract+check ==="
	@mkdir -p $(TMP)
	@awk '/^cat > \/etc\/storage\/ipset_update.sh/{f=1;next} /^EOF_SCRIPT/{f=0} f' install.sh > $(TMP)/ipset_update.sh
	@awk '/^cat > \/etc\/storage\/route_watchdog.sh/{f=1;next} /^EOF_WATCHDOG/{f=0} f' install.sh > $(TMP)/route_watchdog.sh
	@awk '/^cat > \/etc\/storage\/rollback.sh/{f=1;next} /^EOF_ROLLBACK/{f=0} f' install.sh > $(TMP)/rollback.sh
	@awk '/^cat > \/etc\/storage\/selftest.sh/{f=1;next} /^EOF_SELFTEST/{f=0} f' install.sh > $(TMP)/selftest.sh
	@awk '/^cat > \/etc\/storage\/started_script.sh/{f=1;next} /^EOF_STARTED/{f=0} f' install.sh > $(TMP)/started_script.sh
	@for f in ipset_update.sh route_watchdog.sh rollback.sh selftest.sh started_script.sh; do \
		$(SH) -n "$(TMP)/$$f" && echo "  [OK] heredoc $$f ($$(wc -l < $(TMP)/$$f))" || { echo "  [FAIL] $$f"; exit 1; }; done
	@hits=$$(grep -nE 'restore_learned|LEARNED_CACHE|LAST_ANALYZE' $(TMP)/ipset_update.sh $(TMP)/route_watchdog.sh | grep -vE ':[0-9]+:[[:space:]]*#' || true); \
	if [ -n "$$hits" ]; then echo "  [FAIL] learn-everything remnants:"; echo "$$hits"; exit 1; else echo "  [OK] learn-everything removed"; fi
	@grep -q 'setup_dnsmasq' $(TMP)/ipset_update.sh && echo "  [OK] setup_dnsmasq present" || { echo "  [FAIL] no setup_dnsmasq"; exit 1; }

func:
	@echo "=== [3/4] functional ==="
	@wget -q -O $(TMP)/dm.raw "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-ipset.lst" 2>/dev/null || { echo "  [SKIP] no net"; exit 0; }
	@grep '^ipset=/' $(TMP)/dm.raw | sed 's|/vpn_domains$$|/bypass_nets|' > $(TMP)/dm.ipset
	@n=$$(wc -l < $(TMP)/dm.ipset); bad=$$(grep -vc '^ipset=/.*/bypass_nets$$' $(TMP)/dm.ipset || true); \
	  if [ "$$n" -gt 100 ] && [ "$$bad" -eq 0 ]; then echo "  [OK] dnsmasq: $$n lines, junk 0"; else echo "  [FAIL] n=$$n bad=$$bad"; exit 1; fi

# Cross-reference gate: standalone setup scripts must NOT reference the removed
# learn-everything mechanism (PWB_LEARN / learned_ips / restore_learned) as active
# logic. This is the check whose ABSENCE let stale selftest/diagnostic ship in rc1.
# Allowed: historical CHANGELOG lines, and explicit `-D` (delete) cleanup in rollback.
consistency:
	@echo "=== [4/4] cross-ref: no stale learn-everything in shipped scripts ==="
	@files="install.sh selftest.sh diagnostic.sh restore_test.sh rollback.sh uninstall.sh"; \
	for f in $$files; do \
	  hits=$$(grep -nE 'PWB_LEARN|learned_ips|restore_learned|LEARNED_MAX|ANALYZE_INTERVAL' "$$f" \
	    | grep -vE '^[0-9]+:[[:space:]]*#' || true); \
	  if [ -n "$$hits" ]; then \
	    real=$$(echo "$$hits" | grep -vE '(-D PREROUTING|rm -f)') ; \
	    if [ -n "$$real" ]; then echo "  [FAIL] $$f stale refs:"; echo "$$real"; exit 1; fi; \
	  fi; \
	done; \
	echo "  [OK] no stale learn-everything references in shipped scripts"
