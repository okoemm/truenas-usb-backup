#!/bin/bash
# usb-backup.sh – mirrors a TrueNAS dataset to a ZFS pool on a USB disk
#
#   Generated with Claude (Anthropic). Review and test before relying on it.
#
#   Started by udev via systemd-run (99-usb-backup.rules) or manually.
#   DRY_RUN=1           test run without changes to the target
#   MAX_CHANGE_PCT=<n>  change limit in percent (default 20), 100 = off
#
# The source is only ever read. Everything that writes or deletes (rsync --delete,
# zfs snapshot/destroy/rollback/set, zpool scrub/export) affects $TGT_POOL exclusively.

set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

SRC_DS="tank";       SRC="/mnt/tank"        # source dataset and its mountpoint
TGT_POOL="backup";   DST="/mnt/backup"      # pool on the USB disk, imported with altroot=/mnt
TGT_GUID=""                                 # its GUID: udevadm info /dev/sdX1 | grep ID_FS_UUID=
EXCLUDES=()                                 # paths relative to $SRC, e.g. ("/media/cache/" "/tmp/")
KEEP_SNAPS=8                                # generations kept on the disk, 0 = none
KEEP_MONTHLY=0                              # additionally keep one snapshot per month for N months, 0 = off
SCRUB_DAYS=30                               # scrub the disk if its last scrub is older, 0 = never
WARN_FULL_PCT=85                            # warn if the backup pool is fuller than this
MAX_CHANGE_PCT="${MAX_CHANGE_PCT:-20}"      # abort if more existing files would be modified or deleted
CHECK_MIN_FILES=1000                        # also apply that limit to each top-level directory this large, 0 = off
DRY_RUN="${DRY_RUN:-0}"
LOG="/var/log/usb-backup.log"

[ "${SRC_DS%%/*}" != "$TGT_POOL" ] || { echo "Source and target are in the same pool" >&2; exit 1; }
exec 9<"$0"; flock -n 9 || exit 0           # no concurrent runs
cd / || exit 1                              # a working directory on the backup pool would block the export

[ -f "$LOG" ] && (( $(stat -c %s "$LOG") > 10485760 )) && mv -f "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
RUN_START=$(( $(wc -l <"$LOG") + 1 ))

STATUS="FAILED"; REASON="Aborted before completion"; NOTES=""; SCRUBBING=0; PLAN=""

log()  { echo "$(date '+%F %T') $*"; }
note() { NOTES+="- $*"$'\n'; log "NOTE: $*"; }
fail() { REASON="$*"; log "ERROR: $*"; exit 1; }
# Only our pool counts: a foreign pool with the same name is neither used nor exported
pool_imported() { local g; g=$(zpool get -H -o value guid "$TGT_POOL" 2>/dev/null) && [ "$g" = "$TGT_GUID" ]; }
# Field $1 of the pool's last scan (scrub or resilver), from zpool's JSON output (OpenZFS 2.3+)
scan() { zpool status -j --json-int "$TGT_POOL" 2>/dev/null | jq -r --arg p "$TGT_POOL" ".pools[\$p].scan_stats.$1 // empty" 2>/dev/null; }
# End time (epoch) of the last completed scrub, 0 if none
scrub_end() { if [ "$(scan function) $(scan state)" = "SCRUB FINISHED" ]; then scan end_time; else echo 0; fi; }
# Note a nearly full backup pool. A full disk does not free itself: rotation only runs after
# a successful backup, and deletions by rsync free nothing while snapshots hold the blocks.
disk_full() {
    local c; c=$(zpool list -H -o capacity "$TGT_POOL"); c=${c%\%}
    (( c >= WARN_FULL_PCT )) || return 1
    note "Backup pool is $c % full – destroy old snapshots manually (see README)"
}
# Abort the change check for area $1 with $2 of $3 files changed
too_many() {
    fail "Too many changes in $1 ($2 of $3 files, limit $MAX_CHANGE_PCT %) – possible ransomware;" \
         "if intended, run manually with MAX_CHANGE_PCT=100"
}
# Keep the newest $2 snapshots of the pool whose name after "@" starts with $1
rotate() {
    zfs list -H -t snapshot -o name -s creation -d 1 "$TGT_POOL" | grep "^$TGT_POOL@$1" \
        | head -n -"$2" | xargs -rtn1 zfs destroy -r \
        || { STATUS="WARNING"
             note "Could not destroy old snapshots – check 'zfs list -t snapshot -r $TGT_POOL' for holds or clones"; }
}

# Dataset $1 is mounted at $2, and so are all child datasets (canmount=on) below $2.
# An unmounted dataset would appear as an empty directory – rsync --delete would
# then wipe its copy on the target.
mounted_ok() {
    local list
    [ "$(findmnt -n -o SOURCE --mountpoint "$2")" = "$1" ] || return 1
    list=$(zfs list -H -r -o name,canmount,mounted,mountpoint "$1") || return 1
    ! awk -F'\t' -v p="$2" '$2 == "on" && $3 != "yes" && ($4 == p || index($4, p "/") == 1) {
        print "  not mounted: " $1; bad = 1 } END { exit !bad }' <<<"$list"
}

# shellcheck disable=SC2329   # invoked via trap
cleanup() {
    trap '' INT TERM HUP                    # do not interrupt export and mail
    [ -n "$PLAN" ] && rm -rf "$PLAN"
    if pool_imported; then
        if (( SCRUBBING )); then            # interrupted scrub: pause it, the next run resumes it
            zpool scrub -p "$TGT_POOL" && note "Scrub paused – it resumes on the next run"
        fi
        for _ in 1 2 3 4 5 6; do zpool export "$TGT_POOL" && break; sleep 10; done
        if pool_imported; then
            STATUS="FAILED"; note "Pool NOT exported – do not unplug the disk!"
        else
            log "Pool exported – disk can be unplugged"
        fi
    fi

    local body="Status: $STATUS"$'\n'"Reason: $REASON"$'\n'
    [ -n "$NOTES" ] && body+=$'\nNotes:\n'"$NOTES"
    body+=$'\n--- Log (last 60 lines) ---\n'"$(tail -n +"$RUN_START" "$LOG" | tail -n 60)"
    # mail.send is a middleware job: -j waits for the result, so SMTP errors are detected;
    # -jp description logs plain status lines instead of a progress bar.
    # SMTP timeout (30 s) < command timeout (60 s): a slow server fails the job instead of
    # the mail arriving after the script has already reported a failure.
    timeout 60 midclt call -j -jp description mail.send "$(jq -n --arg s "USB backup $TGT_POOL: $STATUS" --arg t "$body" \
        '{subject: $s, text: $t, timeout: 30}')" >/dev/null || log "WARNING: sending mail failed"

    log "=== USB backup finished: $STATUS ==="
    [ "$STATUS" != "FAILED" ]; exit $?
}

# Safeguard: the Post Init setup installs the rule after boot, but a rule installed
# persistently (e.g. in /etc/udev/rules.d) would see the "add" events systemd replays at
# boot (coldplug). Ignore starts while booting or shutting down.
case "$(systemctl is-system-running 2>/dev/null)" in
    initializing|starting|stopping) log "Skipped: system is booting or shutting down"; exit 0 ;;
esac

# Long steps (rsync, waiting for the scrub) run in the background so that a signal
# interrupts 'wait' immediately; the handler stops all of them before cleanup exports the pool.
# shellcheck disable=SC2329,SC2046   # invoked via trap; word splitting of the PID list intended
on_signal() {
    # The backup counts as saved once rsync completed and nothing was written since the newest
    # snapshot (or no snapshots are kept): then the next run does not roll it back.
    if [ "$STATUS" != "FAILED" ] && { [ "$DRY_RUN" = 1 ] || [ "$KEEP_SNAPS" = 0 ] ||
            [ "$(zfs get -Hp -o value written "$TGT_POOL")" = 0 ]; }; then
        STATUS="WARNING"; note "Aborted by signal after the backup was saved"
    else
        STATUS="FAILED"; REASON="Aborted by signal"
    fi
    kill $(jobs -p) 2>/dev/null
    wait; exit 1
}
trap cleanup EXIT
trap on_signal INT TERM HUP

log "=== USB backup started (DRY_RUN=$DRY_RUN) ==="

# Validate settings: an invalid number would make an arithmetic test silently false and
# switch off the change check, snapshots or scrub; an invalid DRY_RUN would run for real
for v in MAX_CHANGE_PCT CHECK_MIN_FILES KEEP_SNAPS KEEP_MONTHLY SCRUB_DAYS WARN_FULL_PCT; do
    [[ ${!v} =~ ^(0|[1-9][0-9]*)$ ]] || fail "$v must be a non-negative integer, got '${!v}'"
done
[[ $DRY_RUN =~ ^[01]$ ]] || fail "DRY_RUN must be 0 or 1, got '$DRY_RUN'"

# 1) Import the target pool – identified by GUID, since pool names are not unique
[[ $TGT_GUID =~ ^[0-9]+$ ]] || fail "TGT_GUID must be the numeric pool GUID, got '$TGT_GUID'"
if pool_imported; then
    note "Pool was already imported (previous run aborted?)"
else
    name=""
    for ((i = 0; i < 24; i++)); do
        name=$(zpool import 2>/dev/null | awk -v g="$TGT_GUID" '$1 == "pool:" { n = $2 } $1 == "id:" && $2 == g { print n }')
        [ -n "$name" ] && break
        sleep 5
    done
    [ -n "$name" ]            || fail "Pool with GUID $TGT_GUID not found within 2 minutes"
    [ "$name" = "$TGT_POOL" ] || fail "Pool with GUID $TGT_GUID is named '$name', expected '$TGT_POOL'"
    zpool import -o altroot=/mnt "$TGT_GUID" || fail "Pool import failed"
    log "Pool found after $(( i * 5 )) s and imported"
fi

# An aborted run (rsync error, signal, power loss) leaves a partial mirror without a snapshot.
# Roll back to the newest snapshot, so the change check compares against a complete backup
# and changes already copied by the aborted run are counted again. Only with KEEP_SNAPS > 0:
# then every complete run ends with a snapshot, and "written" since it must be 0.
if [ "$DRY_RUN" != 1 ] && (( KEEP_SNAPS > 0 )); then
    newest=$(zfs list -H -t snapshot -o name -s creation -d 1 "$TGT_POOL" | tail -n 1)
    if [ -n "$newest" ] && [ "$(zfs get -Hp -o value written "$TGT_POOL")" != 0 ]; then
        zfs rollback "$newest" || fail "Rollback of the incomplete previous run to $newest failed"
        note "Previous run was incomplete – mirror rolled back to ${newest#*@}"
    fi
fi

# 2) Verify source and target – prevents deletions on the target caused by missing mounts
mounted_ok "$SRC_DS" "$SRC"   || fail "Source $SRC is not fully mounted"
[ -n "$(ls -A "$SRC")" ]      || fail "Source $SRC is empty"
mounted_ok "$TGT_POOL" "$DST" || fail "Target $DST is not mounted correctly"
# POSIX ACLs (-A) need acltype=posix on the backup pool, otherwise rsync fails on every file
# that has one. NFSv4 ACLs cannot be copied: ZFS keeps them in a system.* attribute, which
# rsync never transfers.
if [ "$DRY_RUN" != 1 ] && [ "$(zfs get -H -o value acltype "$TGT_POOL")" != posix ]; then
    zfs set acltype=posix "$TGT_POOL" && note "Set acltype=posix on $TGT_POOL to store POSIX ACLs"
fi

# 3) Change check: a dry run counts existing files on the backup that would be modified or
#    deleted. Above MAX_CHANGE_PCT, abort before anything changes – this stops ransomware
#    that encrypts files in place, and mass deletions, before they reach the backup.
#    The limit also applies to each top-level directory with at least CHECK_MIN_FILES files,
#    so a small share cannot be encrypted unnoticed within a large backup.
#    The check fails closed: if the dry run itself fails, the backup does not run.
# Deliberately no --inplace: together with -H it silently corrupts the mirror when a hard
# link is split in the source (one file of a linked pair replaced, e.g. by *arr apps).
opts=(-aHAX --numeric-ids --delete --exclude=".zfs/" "${EXCLUDES[@]/#/--exclude=}")
if (( MAX_CHANGE_PCT < 100 )); then
    # -ii itemizes every file: ">f+++…" new, ">f" content changed, "*deleting" removed.
    # rsync writes into a FIFO instead of a pipe: it stays a direct child, so 'wait' returns
    # its exit code and a signal can stop it.
    PLAN=$(mktemp -d); mkfifo "$PLAN/fifo"
    # awk counts in total and per top-level directory (the path starts in column 13) and
    # reports the directory with the highest share of changes.
    awk -v min="$CHECK_MIN_FILES" '
        { path = substr($0, 13); i = index(path, "/"); top = i ? "/" substr(path, 1, i - 1) : "/" }
        $1 == "*deleting" { dels++; if (path !~ /\/$/) { changed++; existing++; c[top]++; e[top]++ } next }
        substr($1, 2, 1) == "f" && $1 !~ /^.f\+/ { existing++; e[top]++; if ($1 ~ /^>/) { changed++; c[top]++ } }
        END {
            for (t in e) if (min > 0 && e[t] >= min && (w == "" || c[t] / e[t] > c[w] / e[w])) w = t
            print changed + 0, existing + 0, dels + 0, c[w] + 0, e[w] + 0, (w == "" ? "-" : w)
        }' <"$PLAN/fifo" >"$PLAN/counts" &
    rsync "${opts[@]}" --dry-run -ii "$SRC/" "$DST/" >"$PLAN/fifo" &
    wait $!; rc=$?
    wait                                    # awk finishes once rsync has closed the FIFO
    [ "$rc" = 0 ] || [ "$rc" = 24 ] || fail "Change check: rsync dry run failed (exit code $rc)"
    read -r changed existing dels dir_changed dir_existing dir <"$PLAN/counts"
    [[ "$changed $existing $dels $dir_changed $dir_existing" =~ ^[0-9]+( [0-9]+){4}$ ]] \
        || fail "Change check: counting the dry run output failed"
    msg="Change check: $changed of $existing files on the backup would be modified or deleted"
    [ "$dir" != - ] && msg+=", most in $dir: $dir_changed of $dir_existing"
    log "$msg"
    (( changed * 100 <= existing * MAX_CHANGE_PCT ))         || too_many "the backup" "$changed" "$existing"
    (( dir_changed * 100 <= dir_existing * MAX_CHANGE_PCT )) || too_many "$dir" "$dir_changed" "$dir_existing"
    # Cap deletions in the real run at the predicted number (files and directories, as
    # --max-delete counts both) plus a margin for normal changes during the run. Mass
    # deletion while a long run is in progress then stops rsync (exit 25).
    opts+=(--max-delete=$(( dels + 50 )))
fi

# 4) Mirror
[ "$DRY_RUN" = 1 ] && opts+=(--dry-run)
log "rsync $SRC/ -> $DST/"
# shellcheck disable=SC2054   # the comma is part of rsync's --info syntax
rsync "${opts[@]}" --info=stats2,del1 -h "$SRC/" "$DST/" &
wait $!; rc=$?
case $rc in
    0)  STATUS="OK";      REASON="Backup complete" ;;
    24) STATUS="WARNING"; REASON="Backup complete, some source files vanished during the run" ;;
    25) fail "More deletions than the change check predicted – stopped, possible ransomware during the run" ;;
    *)  disk_full; fail "rsync failed (exit code $rc)" ;;
esac

# 5) Preserve this backup generation as a snapshot, rotate older ones
if [ "$DRY_RUN" = 1 ]; then
    note "Dry run – no changes, no snapshot"
else
    if (( KEEP_SNAPS > 0 )); then
        zfs snapshot -r "$TGT_POOL@usb-$(date +%F_%H%M%S)" || { STATUS="WARNING"; note "Snapshot failed"; }
        rotate "usb-[0-9]" "$KEEP_SNAPS"
    fi
    if (( KEEP_MONTHLY > 0 )); then         # the first backup of each month is kept longer
        month="$TGT_POOL@usb-monthly-$(date +%Y-%m)"
        zfs list -H -t snapshot "$month" &>/dev/null \
            || zfs snapshot -r "$month" || { STATUS="WARNING"; note "Monthly snapshot failed"; }
        rotate "usb-monthly-" "$KEEP_MONTHLY"
    fi
fi

# 6) Scrub the disk if its last completed scrub is older than SCRUB_DAYS
if [ "$DRY_RUN" != 1 ] && (( SCRUB_DAYS > 0 )); then
    last=$(scrub_end)
    if ! zpool status -j "$TGT_POOL" &>/dev/null; then
        note "Scrub status unreadable (requires OpenZFS 2.3+) – scrub skipped"
    elif (( $(date +%s) - last > SCRUB_DAYS * 86400 )); then
        t0=$(date +%s)
        log "Scrub started, last completed scrub: $( (( last )) && date -d "@$last" +%F || echo never)"
        SCRUBBING=1                         # set first: a signal from here on pauses the scrub
        zpool scrub "$TGT_POOL"             # starts a scrub, or resumes a paused one
        zpool wait -t scrub "$TGT_POOL" &
        wait $!; SCRUBBING=0
        if (( $(scrub_end) >= t0 )); then
            note "Scrub: $(zpool status "$TGT_POOL" | sed -n 's/^ *scan: //p')"
        else
            STATUS="WARNING"; note "Scrub did not complete – check 'zpool status $TGT_POOL'"
        fi
    fi
fi

# 7) Health and fill level last: errors surface while writing and scrubbing, and the fill
#    level counts only after the snapshot rotation
zpool status -x "$TGT_POOL" | grep -q "is healthy" \
    || { STATUS="WARNING"; note "Target pool reports errors – check 'zpool status -v $TGT_POOL'"; }
disk_full && STATUS="WARNING"
