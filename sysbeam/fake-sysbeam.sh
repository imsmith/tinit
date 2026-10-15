#!/bin/sh
#
# fake-sysbeam.sh - shell stand-in for sysbeam, for testing tinit without a BEAM.
#
#   tinit -> sysbeam ltd -> sysbeam easysec -> sysbeam worker 0..n
#
# The role is argv[1] (tinit also sets argv[0], but a #! script never sees it).
# Each tier runs the next in a respawn loop.
#
# Install:  copy this to /sbin/sysbeam on the initramfs, chmod +x.

ROLE=${1:-$(basename "$0")}
WORKERS=2

log() {
    echo "[sysbeam:${ROLE}] $1"
}

respawn() {
    while :; do "$0" "$@"; sleep 1; done
}

case "$ROLE" in
    ltd)
        log "starting"
        for fs in proc:/proc sysfs:/sys devtmpfs:/dev tmpfs:/tmp tmpfs:/run; do
            log "mounting ${fs#*:}"
            mount -t "${fs%%:*}" "${fs%%:*}" "${fs#*:}" 2>/dev/null
        done
        log "running (config reconciliation loop); supervising easysec"
        respawn easysec
        ;;

    easysec)
        log "starting"
        log "loading security policy (pretend)"
        i=0
        while [ "$i" -lt "$WORKERS" ]; do
            respawn worker "$i" &
            i=$((i + 1))
        done
        log "running (policy enforcement loop); supervising $WORKERS workers"
        wait
        ;;

    worker)
        log "starting worker $2"
        log "starting supervision trees (pretend)"
        if [ "$2" = 0 ]; then
            log "programs tree: interactive shell on ttyS0 (exit -> easysec respawns worker 0)"
            setsid -c sh </dev/ttyS0 >/dev/ttyS0 2>&1
        else
            exec sleep infinity
        fi
        ;;

    *)
        echo "[sysbeam] unknown role: ${ROLE}"
        exit 1
        ;;
esac
