# truenas-usb-backup

Plug-and-forget USB backup for **TrueNAS SCALE**: plug in the backup disk, and a
dataset is mirrored to a ZFS pool on that disk. The pool is exported again
afterwards, and you get a status mail.

> [!NOTE]
> **This script was generated with [Claude](https://claude.ai) (Anthropic).**
> It was tested in a simulated environment and is tested regularly on a real
> TrueNAS SCALE installation. Still, I cannot guarantee that it works on your
> system or with every TrueNAS version. Read the script and do a dry run before
> you rely on it. Use at your own risk.

## What it does

A file-level backup of the data that matters, such as documents, photos and
project folders, onto an external disk that you can unplug and store
elsewhere. **It is not meant to be a replica of the whole pool.**

- **Starts when you plug in the disk** (udev, via `systemd-run`), not at boot.
- **Mirrors one dataset** minus the paths you exclude, including new folders.
  Permissions, POSIX ACLs, extended attributes and hard links are kept.
- **Keeps history:** a snapshot after every successful run (default: the last
  8), optionally one per month for longer.
- **Scrubs the disk** every 30 days.
- **Reports the result of every backup run by mail** and always exports the
  pool, also after errors and signals.

> [!WARNING]
> **SMB shares lose their permissions in the backup.** They use NFSv4 ACLs,
> which rsync cannot copy, so after a restore you have to set the share
> permissions again. Check with `zfs get -r acltype tank`.

## Safety

The source is **only ever read**. Everything that writes or deletes
(`rsync --delete`, `zfs snapshot/destroy/rollback/set`, `zpool scrub/export`)
affects the backup pool only.

| Risk | Guard |
|---|---|
| Source or target not fully mounted, or source empty (rsync would wipe the backup) | abort before rsync; every child dataset with `canmount=on` must be mounted |
| Ransomware, mistakes or mass deletion on the source | **snapshots** on a disk that is usually unplugged, out of reach of ransomware on the NAS. This is the actual protection |
| Such damage silently rotating out the clean snapshots | **change check, an alarm rather than a guarantee:** a dry run counts the files on the backup that would be modified or deleted. Above `MAX_CHANGE_PCT` in total or in a large top-level directory, or if the dry run fails, the run aborts before anything changes. Deletions during the run are capped, and an aborted run is rolled back first. See [Limitations](#limitations) |
| Another disk whose pool has the same name | the pool is identified by its GUID |
| Concurrent runs | lock on the script, fixed systemd unit name |

## Requirements

- TrueNAS SCALE **25.04 or later**. On older versions, replace
  `-j -jp description` in the script with `-job`; without `zpool status -j`,
  the scrub is skipped.
- A USB disk with a ZFS pool (see setup).
- Email configured in TrueNAS (*System → General Settings → Email*), and an
  email address on a local administrator account (*Credentials → Users*). The
  mail goes there.

## Setup

### 1. Create the backup pool (once)

> [!WARNING]
> This erases the disk. Double-check the device ID.

```bash
ls -l /dev/disk/by-id/ | grep usb                 # find the USB disk
zpool create -R /mnt -o ashift=12 -O compression=lz4 -O atime=off -O acltype=posix -O xattr=sa \
    backup /dev/disk/by-id/usb-XXXXXXXX           # -R: mount below /mnt, keep out of the pool cache
zpool get -H -o value guid backup                 # note the GUID for TGT_GUID and the udev rule
zpool export backup
```

Do not import the pool through the TrueNAS web UI: the middleware would then
import it at every boot.

### 2. Install the script

> [!WARNING]
> udev runs the script as **root**. Whoever can change the script or the rule
> file can run any command as root or disable the safety checks. In a shared
> folder, an infected SMB client could do exactly that, or ransomware could
> encrypt them and stop the backups without any mail. On NFSv4 datasets,
> inherited ACL entries can grant write access despite `chmod 700`.

Create a dedicated dataset for both files, e.g. `tank/scripts`, with the preset
*Generic* (POSIX ACLs), and share neither it nor any parent via SMB or NFS.
Copy `usb-backup.sh` and `99-usb-backup.rules.example` there, then:

```bash
chown -R root:root /mnt/tank/scripts
chmod 700 /mnt/tank/scripts /mnt/tank/scripts/usb-backup.sh
chmod 600 /mnt/tank/scripts/99-usb-backup.rules.example
getfacl -p /mnt/tank/scripts /mnt/tank/scripts/*      # only user::, group::, other:: entries
midclt call sharing.smb.query | jq -r '.[].path'      # no share may be this path or a parent of it
midclt call sharing.nfs.query | jq -r '.[].path'      # same for NFS
```

Then edit the configuration block at the top of the script.

### 3. Test

Keep the disk attached since step 1. The rule is not installed yet, so nothing
starts on its own.

```bash
midclt call -j -jp description mail.send '{"subject":"Test","text":"Test"}'; echo "exit: $?"
DRY_RUN=1 /mnt/tank/scripts/usb-backup.sh; cat /var/log/usb-backup.log
```

### 4. Install the udev rule

In `99-usb-backup.rules.example`, set the pool GUID (udev reports it as
`ID_FS_UUID`, see `udevadm info /dev/sdX1`) and the script path. If you
re-create the pool, its GUID changes: update the rule and `TGT_GUID`. The rule
gives the cleanup 300 s on shutdown (`TimeoutStopSec`), enough for export and
mail.

TrueNAS may overwrite `/etc` on updates, so install the rule at every boot under
*System → Advanced Settings → Init/Shutdown Scripts* (type *Command*, *Post
Init*), and run the command once by hand now:

```bash
mkdir -p /run/udev/rules.d && cp /mnt/tank/scripts/99-usb-backup.rules.example /run/udev/rules.d/99-usb-backup.rules && udevadm control --reload
udevadm test /sys/class/block/sdX1 2>&1 | grep usb-backup   # check that udev picks up the rule
```

Then unplug the disk, plug it in again and wait for the mail.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SRC_DS` / `SRC` | `tank` / `/mnt/tank` | source dataset and its mountpoint. For folders from several datasets, use their common parent and exclude the rest |
| `TGT_POOL` / `DST` | `backup` / `/mnt/backup` | pool on the USB disk and its mountpoint |
| `TGT_GUID` | **required** | numeric GUID of that pool |
| `EXCLUDES` | `()` | paths relative to `SRC`, e.g. `("/media/cache/" "/tmp/")` |
| `KEEP_SNAPS` | `8` | snapshots kept, `0` = none (and no rollback of aborted runs) |
| `KEEP_MONTHLY` | `0` | additionally keep the first snapshot of each month for N months |
| `SCRUB_DAYS` | `30` | scrub if the last completed scrub is older, `0` = never |
| `WARN_FULL_PCT` | `85` | warn from this fill level of the backup pool (in %) on |
| `MAX_CHANGE_PCT` | `20` | abort above this share of modified or deleted files on the backup (new files do not count), `100` = off |
| `CHECK_MIN_FILES` | `1000` | apply `MAX_CHANGE_PCT` also to each top-level directory below `SRC` with at least this many files, `0` = total only |
| `DRY_RUN` | `0` | `1` = test run without changes |
| `LOG` | `/var/log/usb-backup.log` | log file, rotated at 10 MB |

`MAX_CHANGE_PCT` and `DRY_RUN` can also be set as environment variables. Invalid
values abort the run with a `FAILED` mail.

## Status mail

| Status | Meaning |
|---|---|
| `OK` | backup complete, snapshot created (if `KEEP_SNAPS` > 0), pool exported |
| `WARNING` | backup complete, but files vanished during the run, the pool reports errors or is nearly full, the snapshot, its rotation or the scrub failed, or the run was aborted after the backup was saved (e.g. during the scrub) |
| `FAILED` | no complete backup, or the pool could not be exported. The mail contains the reason and the log of the run |

> [!IMPORTANT]
> Unplug the disk only after the mail, and never if it says *"Pool NOT
> exported"*. A due scrub can take hours. An interrupted scrub resumes on the
> next run.

## Usage

```bash
/mnt/tank/scripts/usb-backup.sh                       # manual run
MAX_CHANGE_PCT=100 /mnt/tank/scripts/usb-backup.sh    # after large intended changes
tail -n 50 /var/log/usb-backup.log                    # what the last run did
journalctl -u usb-backup                              # only start, end and exit status of udev runs
```

Do not edit or replace the script while a backup is running (`systemctl
is-active usb-backup`): bash reads it while executing.

### Restoring files

Plugging in the disk starts a backup. To only browse it, disable the rule first:

```bash
rm /run/udev/rules.d/99-usb-backup.rules && udevadm control --reload
zpool import -o altroot=/mnt -o readonly=on backup
ls /mnt/backup/.zfs/snapshot/                         # backup generations
cp -a /mnt/backup/.zfs/snapshot/usb-<date>/path/file /mnt/tank/path/
cd / && zpool export backup                           # before unplugging
```

Restore from a snapshot, not from `/mnt/backup`: after a `FAILED` run, it may
be incomplete. Re-enable the rule with the Post Init command from step 4. Test a
restore now and then.

## Limitations

- **The change check looks at the total and at top-level directories, not
  deeper.** With 500,000 media files and a documents share of 20,000 files, a
  fully encrypted share is only 4 % in total. It is caught only if it is a
  top-level directory below `SRC` with at least `CHECK_MIN_FILES` files; a
  smaller or deeper one (e.g. `/shares/documents`) counts in the total only.
  Choose `SRC_DS` so that your shares are directly below it. Slow damage below
  the limit is not caught either.
- **Intended large changes abort the run once**, e.g. renaming or deleting a
  large top-level directory (for rsync, a rename deletes all its files), a
  handful of deletions in a small backup, or a large directory that changes a
  lot by design, such as downloads (better exclude it). Then run once with
  `MAX_CHANGE_PCT=100`.
- **A failed or aborted run is transferred again**: it ends without a snapshot,
  and the next run rolls its partial copy back. So a persistently failing file,
  e.g. an unreadable one (rsync exit code 23), blocks every new generation until
  you fix it or exclude it. The log in the mail names the file.
- **A full disk does not free itself:** snapshots keep deleted and changed data,
  and rotation only runs after a successful backup. The script never deletes
  generations on its own, since ransomware could fill the disk on purpose. Act on
  the *"nearly full"* warning:
  ```bash
  zfs list -t snapshot -o name,used -s creation -r backup
  zfs destroy backup@usb-<date>                         # oldest first, then lower KEEP_SNAPS
  ```
- **Large files with small changes take full space in every snapshot**, because
  rsync writes a changed file as a new copy (e.g. VM images, databases). Exclude
  them and back them up with `zfs send`.
- **A path added to `EXCLUDES` later stays in the backup** with its last state.
  To remove it, disable the rule (see *Restoring files*), then:
  ```bash
  zpool import -o altroot=/mnt backup
  rm -rf /mnt/backup/<excluded path>
  zfs snapshot -r backup@usb-$(date +%F_%H%M%S)        # else the next run rolls the removal back
  cd / && zpool export backup
  ```
- **Not included:** zvols (`zfs list -t volume -r tank`) and the TrueNAS
  configuration (*System → General Settings → Manage Configuration*). For a
  complete copy of a pool, use TrueNAS replication.
- **Live data** such as databases may be inconsistent if it changes during the
  run. Stop the application first if that matters.
- **Locked encrypted child datasets block the backup** on purpose, as their copy
  would otherwise be deleted.
- **Unplugging the disk during a run** suspends the pool, and the export may
  hang until a reboot.

## License

[0BSD](LICENSE): use, copy, modify and distribute freely, with no conditions
and no warranty.
