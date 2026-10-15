#!/bin/sh
#
# fake-sysbeam.sh - test harness for tinit
#
# tinit calls execv("/sbin/sysbeam") with argv[0] set to the role name,
# and argv[1] set to the role name too (a #! script only sees argv[1]).
#
# Install:  copy this to /sbin/sysbeam on the initramfs, chmod +x.

ROLE=${1:-$(basename "$0")}

log() {
    echo "[sysbeam:${ROLE}] $1"
}

case "$ROLE" in
    ltd)
        log "starting"

        # Phase 1: virtual mounts (ltd's first job)
        log "mounting /proc"
        mount -t proc proc /proc 2>/dev/null

        log "mounting /sys"
        mount -t sysfs sys /sys 2>/dev/null

        log "mounting /dev"
        mount -t devtmpfs dev /dev 2>/dev/null

        log "mounting /tmp"
        mount -t tmpfs tmp /tmp 2>/dev/null

        log "mounting /run"
        mount -t tmpfs run /run 2>/dev/null

        # Phase 2: signal tinit that mounts are ready
        log "signaling tinit (SIGUSR1 -> PID 1)"
        kill -USR1 1

        # Phase 3: stay alive, pretend to manage config
        log "running (config reconciliation loop)"
        exec sleep infinity
        ;;

    easysec)
        log "starting"
        log "loading security policy (pretend)"
        log "running (policy enforcement loop)"
        exec sleep infinity
        ;;

    worker)
        log "starting"
        log "starting supervision trees (pretend)"
        log "programs tree: interactive shell on ttyS0 (exit -> tinit respawns worker)"
        exec setsid /bin/sh -c 'exec /bin/sh </dev/ttyS0 >/dev/ttyS0 2>&1'
        ;;

    *)
        echo "[sysbeam] unknown role: ${ROLE}"
        exit 1
        ;;
esac
