#!/bin/bash
#
# HaLOS AP bridged-mode safety watchdog.
#
# When the WiFi AP is switched to Bridged mode (eth0 + wlan0ap joined on br0,
# clients leasing from the upstream gateway), the device's own management IP
# moves from the fixed 10.42.0.1 onto a DHCP lease on br0. If the wired link or
# the upstream DHCP server is unavailable, a headless device would strand itself
# with no reachable address. This watchdog probes br0's health and, if Bridged
# did not come up cleanly, reverts to the Isolated (10.42.0.1 NAT island) shape
# so the device is reachable again.
#
# It is the primary safety guarantee of the AP-integration-mode feature
# (halos-org/cockpit#79). NM checkpoints are not relied on (the add/remove of
# br0 short-circuits checkpoint rollback, and the dual-mode path has none).
#
# Modes (argv[1]):
#   boot   - run at boot (After=NetworkManager.service): wait for network
#            convergence, then verdict. Reverts a Bridged AP that did not come
#            up healthy. No-op when the AP is not Bridged.
#   switch - run by the live-switch deadman armed before an Isolated->Bridged
#            switch (Unit 6): shorter window, same verdict + revert.
#   revert - unconditional revert to Isolated (used by switch-back and
#            disable-while-Bridged). With NO_AP_UP=1, leaves the AP down
#            (disable-while-Bridged).
#
# Contract with the switch orchestration (Unit 6, halos-org/cockpit#83):
#   Before switching, Unit 6 captures eth0's current upstream default-route
#   gateway and writes it to $EXPECTED_GW_FILE. The watchdog reads it only in
#   'switch' mode, where it is authoritative (anti-rogue during the vulnerable
#   transition); it never captures the pre-switch gateway itself (post-switch
#   eth0 is gone). The 'boot' verdict deliberately does NOT enforce gateway
#   identity — a persisted baseline goes stale when the boat changes docks, and
#   bridging onto whatever LAN eth0 reaches is the operator's accepted intent.
#
# Window/timeout constants are conservative starting points; they are tuned on
# hardware in Unit 7 (cockpit-networkmanager-halos#16).

set -o pipefail

# --- Identity / paths (overridable for tests) -------------------------------
BRIDGE="${BRIDGE:-br0}"
UPLINK="${UPLINK:-eth0}"
AP_CON="${AP_CON:-Halos-AP}"
ETH_CON="${ETH_CON:-halos-eth0}"          # standalone DHCP eth0 profile (revert target)
BR_ETH_CON="${BR_ETH_CON:-br0-eth0}"      # bridge port for eth0
AP_IFACE="${AP_IFACE:-wlan0ap}"
ISOLATED_ADDR="${ISOLATED_ADDR:-10.42.0.1}"

STATE_DIR="${STATE_DIR:-/var/lib/halos/ap-bridge}"
EXPECTED_GW_FILE="${EXPECTED_GW_FILE:-$STATE_DIR/expected-gateway}"
RUN_DIR="${RUN_DIR:-/run/halos}"
BREADCRUMB="${BREADCRUMB:-$RUN_DIR/ap-bridge-watchdog.verdict}"
LOCKFILE="${LOCKFILE:-$RUN_DIR/ap-bridge-watchdog.lock}"
KEYFILE="${KEYFILE:-/etc/NetworkManager/system-connections/$AP_CON.nmconnection}"

# Verdict windows (seconds). Boot settle is longer than the live-switch window.
BOOT_SETTLE="${BOOT_SETTLE:-90}"
SWITCH_WINDOW="${SWITCH_WINDOW:-45}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"

NMCLI="${NMCLI:-nmcli}"
IP="${IP:-ip}"
PING="${PING:-ping}"

log() { logger -t ap-bridge-watchdog "$*" 2>/dev/null || true; }

# --- Pure verdict logic (no I/O; unit-tested via a sourced harness) ----------

# Whether a br0 IPv4 address qualifies as a real upstream lease: present, not
# APIPA link-local (169.254/16), and not the Isolated range (10.42.0/24).
lease_qualifies() {
    local cidr="$1"
    [ -n "$cidr" ] || return 1
    case "$cidr" in
        169.254.*) return 1 ;;
        10.42.0.*) return 1 ;;
        *) return 0 ;;
    esac
}

# Decide health from already-gathered probe values. Echoes "healthy" or
# "unhealthy:<reason>". The gateway ping is deliberately NOT an input here: it is
# fail-open (a gateway that drops ICMP must not strand the device), so it can
# only confirm health, never force a revert — it is recorded as a diagnostic in
# the breadcrumb instead of gating the verdict.
#   $1 br0 lease CIDR     $2 default-route-present (1/0)
#   $3 lease gateway      $4 expected gateway (may be empty)
compute_verdict() {
    local lease="$1" have_route="$2" lease_gw="$3" expected_gw="$4"
    if ! lease_qualifies "$lease"; then
        echo "unhealthy:no-qualifying-lease"; return
    fi
    if [ "$have_route" != "1" ]; then
        echo "unhealthy:no-default-route"; return
    fi
    # Reject a lease from the wrong network. Only enforce when we have a
    # recorded baseline; without one we cannot distinguish rogue from real, so
    # fail open on identity (lease + route already passed).
    if [ -n "$expected_gw" ] && [ "$lease_gw" != "$expected_gw" ]; then
        echo "unhealthy:gateway-mismatch"; return
    fi
    echo "healthy"
}

# --- Probe (live I/O) --------------------------------------------------------

probe_br0_lease() {
    $IP -4 addr show "$BRIDGE" 2>/dev/null | awk '/inet /{print $2; exit}'
}
probe_default_route_present() {
    [ -n "$($IP route show default dev "$BRIDGE" 2>/dev/null)" ] && echo 1 || echo 0
}
probe_lease_gateway() {
    $IP route show default dev "$BRIDGE" 2>/dev/null | awk '/default/{print $3; exit}'
}
read_expected_gateway() {
    [ -r "$EXPECTED_GW_FILE" ] && cat "$EXPECTED_GW_FILE" 2>/dev/null || true
}
ping_ok() {
    local gw="$1"
    [ -n "$gw" ] || { echo 0; return; }
    $PING -c1 -W"$PING_TIMEOUT" "$gw" >/dev/null 2>&1 && echo 1 || echo 0
}

# Poll the verdict until healthy or the window elapses. Echoes final verdict.
# $2 is the expected gateway to enforce (empty = fail-open on identity).
await_verdict() {
    local window="$1" expected="$2" deadline verdict lease have_route lease_gw
    deadline=$(( $(date +%s) + window ))
    while :; do
        lease="$(probe_br0_lease)"
        have_route="$(probe_default_route_present)"
        lease_gw="$(probe_lease_gateway)"
        verdict="$(compute_verdict "$lease" "$have_route" "$lease_gw" "$expected")"
        [ "$verdict" = "healthy" ] && { echo "$verdict"; return; }
        [ "$(date +%s)" -ge "$deadline" ] && { echo "$verdict"; return; }
        sleep "$POLL_INTERVAL"
    done
}

is_ap_bridged() {
    # Alias-normalizing read via nmcli (not a keyfile grep): NM reports the
    # value under whichever name (master/controller) regardless of storage.
    local st master
    st="$($NMCLI -t -f connection.slave-type connection show "$AP_CON" 2>/dev/null | cut -d: -f2)"
    master="$($NMCLI -t -f connection.master connection show "$AP_CON" 2>/dev/null | cut -d: -f2)"
    [ "$st" = "bridge" ] || [ -n "$master" ]
}

write_breadcrumb() {
    local verdict="$1" reason="$2"
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    printf 'verdict=%s\nreason=%s\ntimestamp=%s\n' \
        "$verdict" "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BREADCRUMB" 2>/dev/null || true
    chmod 0644 "$BREADCRUMB" 2>/dev/null || true
}

# --- Revert primitive (shared by all revert callers) -------------------------
# Restore the canonical Isolated shape and tear down the bridge. NO_AP_UP=1
# leaves the AP down (disable-while-Bridged). Returns 0 if the live
# post-condition holds (AP on $ISOLATED_ADDR), else triggers terminal fallback.

ap_has_isolated_addr() {
    $IP -4 addr show "$AP_IFACE" 2>/dev/null | grep -q "inet $ISOLATED_ADDR/"
}

revert_to_isolated() {
    log "reverting AP to Isolated"

    # Un-enslave the AP. Per NM, ipv4.* cannot be set in the same call as
    # clearing slave-type, so do membership first, then addressing.
    $NMCLI con mod "$AP_CON" connection.slave-type "" connection.master "" 2>/dev/null || true
    # Canonical Isolated: shared with NO explicit address (factory-compatible,
    # R2), ipv6 ignore. All other AP fields (psk, key-mgmt, ssid, band, channel)
    # are left untouched.
    $NMCLI con mod "$AP_CON" ipv4.method shared ipv4.addresses "" ipv6.method ignore 2>/dev/null || true

    # Restore a standalone DHCP eth0 so the wired link works without the bridge.
    if ! $NMCLI -t -f NAME con show 2>/dev/null | grep -qx "$ETH_CON"; then
        $NMCLI con add type ethernet con-name "$ETH_CON" ifname "$UPLINK" \
            ipv4.method auto ipv6.method auto autoconnect yes 2>/dev/null || true
    fi

    # Tear down the bridge, then bring up standalone eth0. Delete the bridge
    # port/controller profiles BEFORE activating $ETH_CON so two profiles never
    # race to claim eth0 (down alone leaves the autoconnect-capable profile).
    $NMCLI con down "$BR_ETH_CON" 2>/dev/null || true
    $NMCLI con down "$BRIDGE" 2>/dev/null || true
    $NMCLI con delete "$BR_ETH_CON" 2>/dev/null || true
    $NMCLI con delete "$BRIDGE" 2>/dev/null || true
    $NMCLI con up "$ETH_CON" 2>/dev/null || true
    # eth0 carries internet egress for the Isolated NAT island, not the
    # management path (that is the AP on $ISOLATED_ADDR), and may legitimately
    # be down if the wired link is what failed — so log, never gate on it.
    $IP -4 addr show "$UPLINK" 2>/dev/null | grep -q 'inet ' || \
        log "note: $UPLINK has no IPv4 after revert (wired uplink down?)"

    if [ "${NO_AP_UP:-0}" != "1" ]; then
        $NMCLI con up "$AP_CON" 2>/dev/null || true
    else
        return 0
    fi

    # Live post-condition: the AP must actually hold the Isolated address.
    local _
    for _ in 1 2 3 4 5 6; do
        ap_has_isolated_addr && return 0
        sleep 2
    done
    return 1
}

# --- Terminal fallback -------------------------------------------------------
# If the revert could not bring the AP up on $ISOLATED_ADDR, force the AP keyfile
# to the factory Isolated shape by transforming the LIVE keyfile in place, then
# restart NetworkManager. Filesystem + service only — no nmcli orchestration.

terminal_fallback() {
    log "revert post-condition failed; running terminal fallback"
    if [ ! -r "$KEYFILE" ]; then
        # Without the live keyfile we cannot preserve the psk; fabricating a
        # profile risks a renamed or open AP, so surface the failure instead.
        log "terminal fallback: $KEYFILE unreadable; cannot safely recover"
        write_breadcrumb "stranded" "keyfile-unreadable"
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || return 1
    chmod 0600 "$tmp"
    # Transform the live keyfile: force ipv4=shared (no address) + ipv6=ignore,
    # drop bridge membership, and pass [802-11-wireless] / [802-11-wireless-
    # security] (ssid, band, channel, AND the psk) through BYTE-FOR-BYTE — so the
    # psk is never re-escaped/whitespace-stripped and a secured AP never silently
    # becomes open.
    awk '
        /^\[/ {
            sec=$0
            if (sec=="[ipv4]") { print "[ipv4]"; print "method=shared"; print ""; skip=1; v4=1; next }
            if (sec=="[ipv6]") { print "[ipv6]"; print "method=ignore"; print ""; skip=1; v6=1; next }
            if (sec=="[bridge-port]") { skip=1; next }
            skip=0; print; next
        }
        skip { next }
        sec=="[connection]" && /^(master|slave-type|controller|port-type)=/ { next }
        { print }
        END {
            if (!v4) { print "[ipv4]"; print "method=shared" }
            if (!v6) { print "[ipv6]"; print "method=ignore" }
        }
    ' "$KEYFILE" > "$tmp" || { rm -f "$tmp"; return 1; }

    install -D -m 0600 -o root -g root "$tmp" "$KEYFILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    systemctl restart NetworkManager 2>/dev/null || true

    # Never report success blind: confirm the AP actually came up on the
    # Isolated address; otherwise mark the device stranded (observable).
    nm-online -s -q -t 60 2>/dev/null || true
    local _
    for _ in 1 2 3 4 5 6 7 8; do
        if ap_has_isolated_addr; then
            write_breadcrumb "recovered" "terminal-fallback"
            log "terminal fallback recovered the AP on $ISOLATED_ADDR"
            return 0
        fi
        sleep 2
    done
    write_breadcrumb "stranded" "terminal-fallback-failed"
    log "terminal fallback FAILED: AP not up on $ISOLATED_ADDR"
    return 1
}

# --- Orchestration -----------------------------------------------------------

do_revert() {
    if revert_to_isolated; then
        return 0
    fi
    terminal_fallback
}

run_verdict() {
    local mode="$1" window="$2"
    if ! is_ap_bridged; then
        write_breadcrumb "skipped" "ap-not-bridged"
        log "AP is not Bridged; nothing to verify ($mode)"
        return 0
    fi
    # Only now (confirmed Bridged) wait for NM to settle, so a non-bridged
    # device never delays boot on nm-online.
    if [ "$mode" = "boot" ]; then
        nm-online -s -q -t "$BOOT_SETTLE" 2>/dev/null || true
    fi
    # Enforce gateway identity only at switch time, where the captured pre-switch
    # gateway is authoritative (anti-rogue during the vulnerable transition). At
    # boot the persisted baseline can be stale (the boat moved to a new dock), and
    # bridging onto whatever LAN eth0 reaches is the operator's accepted intent
    # (#79), so a qualifying lease + default route is enough — never false-revert
    # a healthy AP just because the network changed.
    local expected=""
    [ "$mode" = "switch" ] && expected="$(read_expected_gateway)"
    local verdict reason
    verdict="$(await_verdict "$window" "$expected")"
    if [ "$verdict" = "healthy" ]; then
        # Fail-open gateway reachability, recorded as a diagnostic only.
        local reach; [ "$(ping_ok "$(probe_lease_gateway)")" = "1" ] && reach=reachable || reach=unreachable
        write_breadcrumb "healthy" "bridged-confirmed gateway=$reach"
        log "Bridged confirmed healthy ($mode); gateway $reach"
        return 0
    fi
    reason="${verdict#unhealthy:}"
    write_breadcrumb "reverted" "$reason"
    log "Bridged unhealthy ($reason); reverting to Isolated ($mode)"
    do_revert
}

main() {
    local mode="${1:-boot}"

    # Serialize the whole verdict+revert. The boot unit, a live-switch deadman,
    # and a manual revert can otherwise overlap and race nmcli / an NM restart
    # into a half-applied state — exactly what this watchdog exists to prevent.
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1 && exec 9>"$LOCKFILE"; then
        flock -w 150 9 || { log "another watchdog run holds the lock; exiting ($mode)"; return 0; }
    fi

    case "$mode" in
        boot)
            run_verdict boot "$BOOT_SETTLE"
            ;;
        switch)
            run_verdict switch "$SWITCH_WINDOW"
            ;;
        revert)
            write_breadcrumb "reverted" "explicit-revert"
            do_revert
            ;;
        *)
            echo "usage: $0 {boot|switch|revert}" >&2
            return 2
            ;;
    esac
}

# Allow sourcing for unit tests without executing main.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
