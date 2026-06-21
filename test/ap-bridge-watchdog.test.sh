#!/bin/bash
# Sourced unit tests for ap-bridge-watchdog.sh pure/near-pure logic. NM/IP are
# stubbed via the script's env-overridable command vars and a dispatching nmcli
# function, so no real NetworkManager is touched. Run: ./run test (or bash this).
#
# Many locals here are consumed by the sourced script, not this file.
# shellcheck disable=SC2034
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$HERE/../files/halos/ap-bridge-watchdog.sh"

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export STATE_DIR="$TD/state" RUN_DIR="$TD/run"
export EXIT_MARKER="$TD/state/last-exit"
export BREADCRUMB="$TD/run/ap-bridge-watchdog.verdict"
export LOCKFILE="$TD/run/lock"
mkdir -p "$STATE_DIR" "$RUN_DIR"

# shellcheck source=/dev/null
source "$WD"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; }

# Dispatching nmcli stub. Behaviour driven by STUB_* globals.
STUB_AP_SLAVE="" STUB_AP_MASTER="" STUB_BR0_STATE="" STUB_ETH_CON="" STUB_AP_DEVCON=""
nmcli() {
    local a="$*"
    case "$a" in
        *"connection.slave-type connection show"*) printf 'connection.slave-type:%s\n' "$STUB_AP_SLAVE" ;;
        *"connection.master connection show"*)     printf 'connection.master:%s\n' "$STUB_AP_MASTER" ;;
        *"GENERAL.STATE device show $BRIDGE"*)      printf 'GENERAL.STATE:%s\n' "$STUB_BR0_STATE" ;;
        *"GENERAL.CONNECTION device show $UPLINK"*) printf '%s\n' "$STUB_ETH_CON" ;;
        *"GENERAL.CONNECTION device show $AP_IFACE"*) printf '%s\n' "$STUB_AP_DEVCON" ;;
        *) : ;;
    esac
}
POLL_INTERVAL=0   # no real sleeps in the re-confirm path

# --- backfill: pure verdict logic -------------------------------------------
lq() { lease_qualifies "$1" && echo yes || echo no; }
ck "lease empty"    no  "$(lq '')"
ck "lease 169.254"  no  "$(lq '169.254.1.5/16')"
ck "lease 10.42"    no  "$(lq '10.42.0.1/24')"
ck "lease real"     yes "$(lq '192.168.8.50/24')"
ck "verdict healthy"   "healthy"                      "$(compute_verdict '192.168.8.50/24' 1 '192.168.8.1' '192.168.8.1')"
ck "verdict gw-mismatch" "unhealthy:gateway-mismatch" "$(compute_verdict '192.168.8.50/24' 1 '10.0.0.1' '192.168.8.1')"
ck "verdict no-route"  "unhealthy:no-default-route"   "$(compute_verdict '192.168.8.50/24' 0 '192.168.8.1' '')"

# --- is_partial_switch: positive half-state discriminator -------------------
ps() { is_partial_switch && echo yes || echo no; }
STUB_BR0_STATE="100 (connected)"; STUB_ETH_CON="br0-eth0"
ck "partial: br0 up + eth0 enslaved"        yes "$(ps)"
STUB_BR0_STATE="30 (disconnected)"; STUB_ETH_CON="br0-eth0"
ck "partial: br0 down -> no"                no  "$(ps)"
STUB_BR0_STATE="100 (connected)"; STUB_ETH_CON="Wired connection 1"
ck "partial: eth0 standalone -> no"         no  "$(ps)"

# --- mark_exit: gate solely on SERVICE_RESULT -------------------------------
rm -f "$EXIT_MARKER"
( SERVICE_RESULT=success; mark_exit ); ck "mark_exit success -> rc0" "0" "$?"
ck "mark_exit success -> no marker" "no" "$([ -e "$EXIT_MARKER" ] && echo yes || echo no)"
( unset SERVICE_RESULT; mark_exit ); ck "mark_exit unset(=success) -> no marker" "no" "$([ -e "$EXIT_MARKER" ] && echo yes || echo no)"
( SERVICE_RESULT=timeout EXIT_STATUS=; mark_exit )
ck "mark_exit timeout -> marker written" "yes" "$([ -e "$EXIT_MARKER" ] && echo yes || echo no)"
ck "mark_exit timeout -> verdict=stranded" "stranded" "$(sed -n 's/^verdict=//p' "$EXIT_MARKER")"
ck "mark_exit timeout -> reason service-timeout" "service-timeout" "$(sed -n 's/^reason=//p' "$EXIT_MARKER")"
rm -f "$EXIT_MARKER"

# --- run_verdict: switch-mode half-switch revert ----------------------------
AP_CON="Halos-X"
do_revert() { echo "REVERTED" >> "$TD/revert.log"; }   # override the real teardown
read_expected_gateway() { echo ""; }
crumb_reason() { sed -n 's/^reason=//p' "$BREADCRUMB"; }
crumb_verdict() { sed -n 's/^verdict=//p' "$BREADCRUMB"; }

# not bridged + partial present + switch mode -> revert
: > "$TD/revert.log"; : > "$BREADCRUMB"
STUB_AP_SLAVE="" STUB_AP_MASTER="" STUB_BR0_STATE="100 (connected)" STUB_ETH_CON="br0-eth0"
run_verdict switch 0
ck "switch+partial -> verdict reverted"  "reverted"       "$(crumb_verdict)"
ck "switch+partial -> reason partial"    "partial-switch" "$(crumb_reason)"
ck "switch+partial -> do_revert ran"     "REVERTED"       "$(cat "$TD/revert.log" 2>/dev/null)"

# not bridged + NOT partial (eth0 standalone) + switch -> skip, no revert
: > "$TD/revert.log"; : > "$BREADCRUMB"
STUB_ETH_CON="Wired connection 1"
run_verdict switch 0
ck "switch+not-partial -> skipped"       "skipped"        "$(crumb_verdict)"
ck "switch+not-partial -> no revert"     ""               "$(cat "$TD/revert.log" 2>/dev/null)"

# CRITICAL regression guard: boot + partial present -> skip, NEVER revert
: > "$TD/revert.log"; : > "$BREADCRUMB"
STUB_ETH_CON="br0-eth0"
run_verdict boot 0
ck "boot+partial -> skipped (no revert)" "skipped"        "$(crumb_verdict)"
ck "boot+partial -> NO revert"           ""               "$(cat "$TD/revert.log" 2>/dev/null)"

# --- main(): empty-AP_CON dispatch is mode-aware ----------------------------
# AP_CON="" (defined-empty) mirrors the script's own `AP_CON="${AP_CON:-}"`; the
# real invocation never leaves it unset, so don't `unset` it under set -u.
STUB_AP_DEVCON=""   # discovery finds nothing bound to the AP iface
: > "$BREADCRUMB"
( AP_CON=""; BOOT_SETTLE=0; main boot >/dev/null 2>&1 ); ck "main boot + no AP_CON -> rc0" "0" "$?"
ck "main boot + no AP_CON -> undetermined" "undetermined" "$(crumb_verdict)"
ck "main boot + no AP_CON -> reason" "ap-con-not-discovered" "$(crumb_reason)"
( AP_CON=""; main stash >/dev/null 2>&1 ); ck "main stash + no AP_CON -> rc1 (apply aborts)" "1" "$?"
( AP_CON=""; main up >/dev/null 2>&1 );    ck "main up + no AP_CON -> rc1 (apply aborts)"    "1" "$?"

echo "---"; echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
