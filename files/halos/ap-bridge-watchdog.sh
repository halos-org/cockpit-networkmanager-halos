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
#   stash  - capture the AP psk to the persistent stash. Run by the enter-Bridged
#            orchestration BEFORE enslaving the AP, while the psk is still in the
#            keyfile (NM drops the in-file psk the moment the AP becomes a bridge
#            port). Every post-enslave activation sources the psk from the stash.
#   up     - psk-aware AP activation: re-feed the stashed psk via a transient
#            passwd-file (a post-enslave con-up demands secrets even with the psk
#            stored). Shared with the enter-Bridged orchestration (Unit 6).
#   boot   - run at boot (After=NetworkManager.service): wait for network
#            convergence, then verdict. Reverts a Bridged AP that did not come
#            up healthy; re-feeds the psk to a healthy one (NM cannot autoconnect
#            an enslaved AP without the dropped in-file psk). No-op when the AP
#            is not Bridged.
#   switch - run by the live-switch deadman armed before an Isolated->Bridged
#            switch (Unit 6): shorter window, same verdict + revert. Also reverts
#            a half-built bridge left by an apply that aborted before enslaving
#            the AP (a partial switch), which boot deliberately does not.
#   revert - unconditional revert to Isolated (used by switch-back and
#            disable-while-Bridged). Restores the psk into the keyfile and clears
#            the stash. With NO_AP_UP=1, leaves the AP down
#            (disable-while-Bridged).
#   mark-exit - ExecStopPost hook: on a non-clean service exit (timeout / kill)
#            persist a stranded marker to $STATE_DIR (the /run breadcrumb is
#            tmpfs). No AP discovery, no lock, no NM interaction.
#
# psk handling (security): the psk only ever lives in 0600-root files — the NM
# keyfile, the stash, and a transient passwd-file during activation. NM drops the
# in-file psk the moment the AP becomes a bridge port, so the stash (captured
# pre-enslave) is the recoverable source while Bridged; it is cleared on revert,
# leaving the keyfile as the single copy while Isolated. (NM re-persists the psk
# into the keyfile on a successful psk-flags=0 activation, so while Bridged both
# may transiently hold it; both are 0600 root.) The stash holds the psk in its
# verbatim keyfile-escaped form, so restoring it into a keyfile is byte-for-byte
# (NM's escaping, e.g. a leading space written as \s, is preserved — a
# hand-rewritten psk would risk an admin lockout). Activations unescape it into a
# transient 0600 passwd-file; the psk never lands in argv, a log, or the
# breadcrumb.
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
# AP_CON is discovered from the AP interface at run time (see main) — the AP
# connection id is hostname-derived (e.g. Halos-B7E8), not a fixed "Halos-AP".
AP_CON="${AP_CON:-}"
ETH_CON="${ETH_CON:-halos-eth0}"          # standalone DHCP eth0 profile (revert target)
BR_ETH_CON="${BR_ETH_CON:-br0-eth0}"      # bridge port for eth0
AP_IFACE="${AP_IFACE:-wlan0ap}"
ISOLATED_ADDR="${ISOLATED_ADDR:-10.42.0.1}"

STATE_DIR="${STATE_DIR:-/var/lib/halos/ap-bridge}"
EXPECTED_GW_FILE="${EXPECTED_GW_FILE:-$STATE_DIR/expected-gateway}"
STASH="${STASH:-$STATE_DIR/psk}"   # 0600 root; verbatim keyfile-escaped psk while Bridged
EXIT_MARKER="${EXIT_MARKER:-$STATE_DIR/last-exit}"  # persistent non-clean-exit marker (survives reboot)
RUN_DIR="${RUN_DIR:-/run/halos}"
BREADCRUMB="${BREADCRUMB:-$RUN_DIR/ap-bridge-watchdog.verdict}"
LOCKFILE="${LOCKFILE:-$RUN_DIR/ap-bridge-watchdog.lock}"
KEYFILE="${KEYFILE:-}"   # derived from the discovered AP_CON in main()

# Verdict windows (seconds). Boot settle is longer than the live-switch window.
BOOT_SETTLE="${BOOT_SETTLE:-90}"
SWITCH_WINDOW="${SWITCH_WINDOW:-45}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
FLOCK_WAIT="${FLOCK_WAIT:-150}"   # max wait for the serialization lock

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

# Positive partial-switch discriminator: the bridge is built (br0 connected with
# eth0 enslaved as its port) but the AP is NOT a bridge port. This is the unique
# signature an aborted enter-Bridged leaves (eth0 was downed and enslaved before
# the AP enslave step failed). It must NOT match a healthy completed bridge —
# there the AP *is* a port — so callers gate this behind `! is_ap_bridged`.
is_partial_switch() {
    local br_state eth_con
    # nmcli GENERAL.STATE is "<code> (<text>)"; 100 == connected. Match the code,
    # not the text — "disconnected" contains the substring "connected".
    br_state="$($NMCLI -t -f GENERAL.STATE device show "$BRIDGE" 2>/dev/null | cut -d: -f2)"
    eth_con="$($NMCLI -t -g GENERAL.CONNECTION device show "$UPLINK" 2>/dev/null)"
    [ "${br_state%% *}" = "100" ] || return 1
    [ "$eth_con" = "$BR_ETH_CON" ]
}

# ExecStopPost hook: persist a stranded marker on a NON-CLEAN exit (systemd
# timeout / SIGKILL mid-revert). The /run verdict breadcrumb is tmpfs (lost on
# power-cycle) and is never written when systemd kills the process, so an
# operator otherwise can't tell after a reboot that the last run was force-
# terminated. Gate SOLELY on $SERVICE_RESULT: for a Type=oneshot timeout/signal,
# $EXIT_STATUS is empty or a signal NAME (never a numeric 0), so a numeric
# comparison would misfire on exactly the case this exists to catch.
mark_exit() {
    [ "${SERVICE_RESULT:-success}" = "success" ] && return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf 'verdict=stranded\nreason=service-%s\nexit_status=%s\ntimestamp=%s\n' \
        "${SERVICE_RESULT:-unknown}" "${EXIT_STATUS:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$EXIT_MARKER" 2>/dev/null || true
    chmod 0644 "$EXIT_MARKER" 2>/dev/null || true
    # Don't claim success blind: only log "wrote" if the marker actually landed.
    if [ -e "$EXIT_MARKER" ]; then
        log "non-clean exit (SERVICE_RESULT=${SERVICE_RESULT:-unknown}); wrote stranded marker"
    else
        log "non-clean exit (SERVICE_RESULT=${SERVICE_RESULT:-unknown}); FAILED to write stranded marker"
    fi
}

write_breadcrumb() {
    local verdict="$1" reason="$2"
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    printf 'verdict=%s\nreason=%s\ntimestamp=%s\n' \
        "$verdict" "$reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BREADCRUMB" 2>/dev/null || true
    chmod 0644 "$BREADCRUMB" 2>/dev/null || true
}

# The AP connection's keyfile path. NM does not rename the keyfile when the
# connection id changes, so it cannot be derived from the id — discover it
# (UUID-keyed, so a connection name containing a colon can't mis-split).
ap_keyfile() {
    local uuid
    uuid="$($NMCLI -t -g connection.uuid connection show "$AP_CON" 2>/dev/null)"
    [ -n "$uuid" ] || return 1
    $NMCLI -t -f UUID,FILENAME connection show 2>/dev/null \
        | awk -F: -v u="$uuid" '$1==u{print substr($0, length(u)+2); exit}'
}

# --- psk stash + (un)escape -------------------------------------------------
# NM removes the in-file psk the moment the AP becomes a bridge port, so the psk
# can only be captured BEFORE the first enslave. The stash holds it in its
# verbatim keyfile-escaped form (byte-for-byte what NM wrote), which restores
# into a keyfile losslessly; activations unescape it for the passwd-file.

# Capture the AP psk to the stash from the live keyfile (called pre-enslave).
# An open AP has no in-file psk: clear any stale stash and succeed. Fails (so the
# enter-Bridged `set -e` aborts before enslaving) only on a write error — better
# to abort the switch than to enslave with no recoverable psk.
stash_psk() {
    local psk tmp
    [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ] || { log "stash: keyfile unreadable ($KEYFILE)"; return 1; }
    psk="$(sed -n 's/^psk=//p' "$KEYFILE" 2>/dev/null | head -1)"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ -z "$psk" ]; then
        rm -f "$STASH" 2>/dev/null || true
        log "stash: no in-file psk (open AP?); nothing to stash"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    chmod 0600 "$tmp"
    printf '%s' "$psk" > "$tmp" || { rm -f "$tmp"; return 1; }
    install -D -m 0600 -o root -g root "$tmp" "$STASH" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    log "stash: psk captured pre-enslave"
}

clear_stash() { rm -f "$STASH" 2>/dev/null || true; }

# GKeyFile string unescape (\s space, \t tab, \n newline, \r CR, \\ backslash).
# Value passed via the environment so awk does not re-process its backslashes.
gkeyfile_unescape() {
    V="$1" awk 'BEGIN{
        v=ENVIRON["V"]
        gsub(/\\\\/, "\001", v)
        gsub(/\\s/, " ", v)
        gsub(/\\t/, "\t", v)
        gsub(/\\n/, "\n", v)
        gsub(/\\r/, "\r", v)
        gsub(/\001/, "\\", v)
        printf "%s", v
    }'
}

# The verbatim (keyfile-escaped) psk, for byte-for-byte injection into a keyfile.
# Stash first (authoritative while Bridged), else the keyfile's own psk.
psk_verbatim() {
    local v
    if [ -r "$STASH" ]; then
        v="$(cat "$STASH" 2>/dev/null)"
        [ -n "$v" ] && { printf '%s' "$v"; return; }
    fi
    [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ] && sed -n 's/^psk=//p' "$KEYFILE" 2>/dev/null | head -1
}

# The raw (unescaped) psk secret, for the passwd-file. Stash first (unescaped);
# else nmcli -s (already raw, works only while not enslaved); else the keyfile.
psk_raw() {
    local v
    if [ -r "$STASH" ]; then
        v="$(cat "$STASH" 2>/dev/null)"
        [ -n "$v" ] && { gkeyfile_unescape "$v"; return; }
    fi
    v="$($NMCLI -s -g 802-11-wireless-security.psk connection show "$AP_CON" 2>/dev/null)"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
    if [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ]; then
        v="$(sed -n 's/^psk=//p' "$KEYFILE" 2>/dev/null | head -1)"
        [ -n "$v" ] && gkeyfile_unescape "$v"
    fi
}

# Bring the AP up, re-feeding the psk via a transient 0600 passwd-file. After an
# enslave NM raises "Secrets were required" on the next activation even with the
# psk stored, so an explicit re-feed is required (verified on hardware). The psk
# never lands in argv, a log, or the breadcrumb.
ap_up() {
    local psk pf rc
    psk="$(psk_raw)"
    if [ -n "$psk" ]; then
        pf="$(mktemp)" || return 1
        chmod 0600 "$pf"
        printf '802-11-wireless-security.psk:%s\n' "$psk" > "$pf"
        unset psk
        $NMCLI connection up "$AP_CON" passwd-file "$pf" 2>/dev/null; rc=$?
        rm -f "$pf"
        return $rc
    fi
    $NMCLI connection up "$AP_CON" 2>/dev/null
}

# Transform the AP keyfile to the Isolated shape on stdout: force ipv4=shared (no
# address) + ipv6=ignore, drop bridge membership, and ensure [wifi-security]
# carries psk=<verbatim>. The psk is injected from the stash (or the keyfile's
# own psk) BYTE-FOR-BYTE via the environment so NM's escaping is preserved — a
# hand-rewritten psk would risk an admin lockout. A secured AP never silently
# becomes open: an existing psk line is dropped and re-emitted from the source.
rewrite_keyfile_isolated() {
    local src="$1"
    PSK_VERBATIM="$(psk_verbatim)" awk '
        /^\[/ {
            sec=$0
            if (sec=="[ipv4]") { print "[ipv4]"; print "method=shared"; print ""; skip=1; v4=1; next }
            if (sec=="[ipv6]") { print "[ipv6]"; print "method=ignore"; print ""; skip=1; v6=1; next }
            if (sec=="[bridge-port]") { skip=1; next }
            skip=0; print
            if ((sec=="[wifi-security]" || sec=="[802-11-wireless-security]") && ENVIRON["PSK_VERBATIM"]!="")
                print "psk=" ENVIRON["PSK_VERBATIM"]
            next
        }
        skip { next }
        sec=="[connection]" && /^(master|slave-type|controller|port-type)=/ { next }
        (sec=="[wifi-security]" || sec=="[802-11-wireless-security]") && /^psk=/ { next }
        { print }
        END {
            if (!v4) { print "[ipv4]"; print "method=shared" }
            if (!v6) { print "[ipv6]"; print "method=ignore" }
        }
    ' "$src"
}

# Restore the live keyfile to the Isolated shape (with the psk) and reload NM so
# the persisted profile regains the psk for the next boot. Returns 0 only if the
# keyfile now actually holds the psk (the caller may then clear the stash, the
# last copy). A secured profile (key-mgmt set) with no psk= line means the source
# psk was unavailable — fail so the stash is kept and the failure surfaces.
restore_isolated_keyfile() {
    local tmp
    [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ] || return 1
    tmp="$(mktemp)" || return 1
    chmod 0600 "$tmp"
    rewrite_keyfile_isolated "$KEYFILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    install -D -m 0600 -o root -g root "$tmp" "$KEYFILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    $NMCLI connection reload 2>/dev/null || true
    # A secured AP must keep its psk: not-secured OR psk-present is success.
    ! grep -qE '^key-mgmt=' "$KEYFILE" 2>/dev/null || grep -q '^psk=' "$KEYFILE" 2>/dev/null
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

    # Restore the psk into the keyfile (NM dropped the in-file copy while the AP
    # was a bridge port) so the persisted profile activates on the next boot. On
    # success the keyfile is again the single psk copy and the stash can be
    # cleared; until then the stash is the only copy, so keep it.
    local kf_ok=1
    restore_isolated_keyfile || kf_ok=0

    if [ "${NO_AP_UP:-0}" = "1" ]; then
        # disable-while-Bridged: leave the AP down, but the keyfile is now
        # Isolated+psk so a later re-enable works.
        [ "$kf_ok" = "1" ] && clear_stash
        return 0
    fi

    ap_up || true

    # Live post-condition: the AP must actually hold the Isolated address.
    local _
    for _ in 1 2 3 4 5 6; do
        if ap_has_isolated_addr; then
            [ "$kf_ok" = "1" ] && clear_stash
            return 0
        fi
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
        # Without the live keyfile we cannot reconstruct the AP safely (a
        # fabricated profile risks a renamed or open AP), so surface the failure.
        log "terminal fallback: $KEYFILE unreadable; cannot safely recover"
        write_breadcrumb "stranded" "keyfile-unreadable"
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || { write_breadcrumb "stranded" "terminal-fallback-write-failed"; return 1; }
    chmod 0600 "$tmp"
    # Transform the live keyfile to the Isolated shape, re-injecting the stashed
    # psk byte-for-byte (NM dropped the in-file copy while the AP was a bridge
    # port, so it cannot be passed through — it must come from the stash).
    rewrite_keyfile_isolated "$KEYFILE" > "$tmp" || { rm -f "$tmp"; write_breadcrumb "stranded" "terminal-fallback-write-failed"; return 1; }

    install -D -m 0600 -o root -g root "$tmp" "$KEYFILE" 2>/dev/null || { rm -f "$tmp"; write_breadcrumb "stranded" "terminal-fallback-write-failed"; return 1; }
    rm -f "$tmp"
    systemctl restart NetworkManager 2>/dev/null || true

    # Never report success blind: confirm the AP actually came up on the
    # Isolated address; otherwise mark the device stranded (observable).
    nm-online -s -q -t 60 2>/dev/null || true
    local _
    for _ in 1 2 3 4 5 6 7 8; do
        if ap_has_isolated_addr; then
            clear_stash
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
        # Switch mode only: an aborted enter-Bridged can strand the device in a
        # half-built bridge (br0 up, eth0 enslaved) with the AP NOT yet a port.
        # Revert that partial state back to a reachable Isolated AP. Boot and all
        # other modes keep the plain skip — a legitimately non-bridged device
        # must never be reverted (that would be a needless outage).
        if [ "$mode" = "switch" ] && is_partial_switch; then
            # is_ap_bridged is a single un-retried nmcli read and switch mode has
            # no boot settle, so re-confirm after a short pause that the AP is
            # still not a port (and the half-state persists) before acting on a
            # possible transient false-negative.
            sleep "$POLL_INTERVAL"
            if ! is_ap_bridged && is_partial_switch; then
                write_breadcrumb "reverted" "partial-switch"
                log "partial switch detected (bridge built, AP not enslaved); reverting"
                do_revert
                return
            fi
        fi
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
        # br0 (the management path) is healthy; ensure the AP radio is actually
        # serving. NM cannot autoconnect an enslaved AP after a reboot because it
        # dropped the in-file psk, so re-feed it from the stash (idempotent when
        # the AP is already up, e.g. the switch apply just brought it up). Note a
        # re-feed failure in the breadcrumb rather than reporting healthy blind —
        # management via br0 still works, so this is observability, not a revert.
        local ap_note=""; ap_up || ap_note=" ap-refeed-failed"
        # Fail-open gateway reachability, recorded as a diagnostic only.
        local reach; [ "$(ping_ok "$(probe_lease_gateway)")" = "1" ] && reach=reachable || reach=unreachable
        write_breadcrumb "healthy" "bridged-confirmed gateway=$reach$ap_note"
        log "Bridged confirmed healthy ($mode); gateway $reach$ap_note"
        return 0
    fi
    reason="${verdict#unhealthy:}"
    write_breadcrumb "reverted" "$reason"
    log "Bridged unhealthy ($reason); reverting to Isolated ($mode)"
    do_revert
}

main() {
    local mode="${1:-boot}"

    # mark-exit is an ExecStopPost hook: no AP discovery, no lock, no NM — it only
    # records systemd's exit result. Handle it before everything else.
    if [ "$mode" = "mark-exit" ]; then
        mark_exit
        return
    fi

    # Discover the managed AP connection by its interface (id is hostname-derived,
    # not a fixed name). An explicit AP_CON env still overrides.
    if [ -z "$AP_CON" ]; then
        # At boot the AP interface may not yet be claimed by a connection: the
        # unit is ordered only After=NetworkManager.service, which gates on NM
        # *starting*, not on connection activation. Discovering too early returns
        # empty. Wait, bounded, for the binding. The AP rides wlan0ap independent
        # of the uplink, so this resolves quickly for an Isolated device too.
        if [ "$mode" = "boot" ]; then
            local _deadline; _deadline=$(( $(date +%s) + BOOT_SETTLE ))
            while [ -z "$($NMCLI -t -g GENERAL.CONNECTION device show "$AP_IFACE" 2>/dev/null)" ] \
                  && [ "$(date +%s)" -lt "$_deadline" ]; do sleep 1; done
        fi
        AP_CON="$($NMCLI -t -g GENERAL.CONNECTION device show "$AP_IFACE" 2>/dev/null)"
    fi
    # No connection is bound to the AP interface. Never synthesize a fake id (the
    # old "Halos-AP" fallback): is_ap_bridged / keyfile derivation off a
    # non-existent connection would FALSE-SKIP a possibly-unhealthy Bridged AP.
    # Apply-gated modes (stash/up) FAIL so the enter-Bridged `set -e` aborts;
    # verdict modes surface it honestly and do nothing destructive (there is
    # nothing safe to revert when the AP can't even be identified).
    if [ -z "$AP_CON" ]; then
        log "AP connection not discovered on $AP_IFACE ($mode)"
        case "$mode" in
            stash|up) return 1 ;;
            *) write_breadcrumb "undetermined" "ap-con-not-discovered"; return 0 ;;
        esac
    fi
    # Discover the keyfile path (not derivable from the id); fall back to the
    # id-based path only if discovery fails.
    KEYFILE="${KEYFILE:-$(ap_keyfile)}"
    KEYFILE="${KEYFILE:-/etc/NetworkManager/system-connections/$AP_CON.nmconnection}"

    # Serialize the whole verdict+revert. The boot unit, a live-switch deadman,
    # and a manual revert can otherwise overlap and race nmcli / an NM restart
    # into a half-applied state — exactly what this watchdog exists to prevent.
    # On lock-timeout the exit code is mode-aware: the apply-gated modes
    # (stash/up, run under the enter-Bridged `set -e`) FAIL so the apply aborts
    # before enslaving with no captured psk; the verdict modes succeed-quietly
    # because another run legitimately owns the critical section.
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1 && exec 9>"$LOCKFILE"; then
        flock -w "$FLOCK_WAIT" 9 || {
            log "another watchdog run holds the lock; exiting ($mode)"
            case "$mode" in stash|up) return 1 ;; *) return 0 ;; esac
        }
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
        up)
            # psk-aware AP activation, shared with the switch orchestration
            # (Unit 6) so the post-enslave con-up re-feeds the psk identically.
            ap_up
            ;;
        stash)
            # Capture the psk before the enter-Bridged enslave drops the in-file
            # copy. Any failure (write error, or the lock-timeout above)
            # propagates so the apply's `set -e` aborts before enslaving — better
            # than enslaving with no recoverable psk source.
            stash_psk
            ;;
        *)
            echo "usage: $0 {stash|up|boot|switch|revert|mark-exit}" >&2
            return 2
            ;;
    esac
}

# Allow sourcing for unit tests without executing main.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
