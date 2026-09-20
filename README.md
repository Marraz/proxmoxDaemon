# nfs-stale-monitor

A small daemon that runs on **each Proxmox node** in a cluster to watch the
node's NFS mounts and automatically recover them when they go stale.

When an NFS server dies or a network path drops, the mountpoints on each node
can turn into *stale* or *hung* handles. Anything that touches them hangs, and
Proxmox storage that lives on NFS becomes unusable. This daemon watches for
that and fixes it on the node where it is running:

1. On a fixed, **configurable interval**, it probes every NFS / NFS4 mountpoint.
2. A mount that no longer responds (hung, or returning `ESTALE` / *"stale file
   handle"*) is **force-umounted** (with a lazy-umount fallback for wedged
   mounts).
3. After the full pass, if at least one mount was reclaimed, it runs
   **`mount -a`** so the unmounted (stale) mounts are **remounted** from
   `/etc/fstab`.

It is deliberately simple and safe: it only ever touches **NFS** mounts, it
does a full check-and-remount pass, and it logs everything to the journal.

## How it works

- **Source of truth:** NFS mountpoints are read from `/proc/mounts`
  (any fstype starting with `nfs` — `nfs`, `nfs4`, `nfsv4`, …), so it picks up
  whatever the node actually has mounted, regardless of how it was configured.
- **Staleness probe:** each mountpoint is checked with `stat`, wrapped in
  `timeout`. A healthy mount returns in milliseconds. A mount that blocks for
  longer than `STAT_TIMEOUT` seconds is considered **hung**; a `stat` that
  fails is considered **stale**. Both are reclaimed.
- **Reclaim:** `umount -f <mp>` is tried first (bounded by `UMOUNT_TIMEOUT`).
  If the mount is fully wedged, it falls back to `umount -l <mp>` (lazy), which
  detaches immediately. It then verifies the mount is actually gone.
- **Remount:** after scanning *all* mounts, if any were reclaimed it runs
  `mount -a` to remount them. If nothing was stale, `mount -a` is skipped so
  healthy mounts are never touched.

Because it remounts from `/etc/fstab`, the NFS mounts are expected to be listed
there (which is how Proxmox cluster / ZFS + NFS datastores are typically set
up). Mounts that are not in `/etc/fstab` will be unmounted but not remounted —
so keep your NFS entries in `/etc/fstab`.

## Requirements

- A Proxmox (Debian-based) node, with **root** (the daemon must be able to
  `stat` and `umount`).
- Standard tools: `bash`, `awk`, `stat`, `timeout`, `mountpoint`, `mount`,
  `umount` (all present by default on Proxmox).
- `systemd` (standard on Proxmox).

No external packages or dependencies are needed.

## Installation

Install per-node. On **each Proxmox node**, run:

```sh
git clone git@gitlab.marraz.me:Marraz/proxmoxdaemon.git
cd proxmoxdaemon
sudo ./init.sh
```

`init.sh` is idempotent and does the following:

1. Installs the daemon to `/usr/local/bin/nfs-stale-monitor`.
2. Creates the config file at `/etc/nfs-stale-monitor/nfs-stale-monitor.conf`
   — **only if it does not already exist**, so your tuned settings are never
   clobbered on re-run.
3. Installs the systemd unit at `/etc/systemd/system/nfs-stale-monitor.service`
   and runs `systemctl daemon-reload`.
4. Enables and (re)starts the service.

Afterwards, on every node:

```sh
systemctl status  nfs-stale-monitor   # is it running?
journalctl -u nfs-stale-monitor -f    # live log
```

The service is `WantedBy=multi-user.target` with `Restart=always`, so it comes
up on boot and is restarted if it ever exits.

## Configuration

Edit **`/etc/nfs-stale-monitor/nfs-stale-monitor.conf`**, then restart the
service:

```sh
sudo nano /etc/nfs-stale-monitor/nfs-stale-monitor.conf
sudo systemctl restart nfs-stale-monitor
```

The file is plain shell (it is `source`d by the daemon):

| Variable         | Default | Meaning |
|------------------|---------|---------|
| `INTERVAL`       | `60`    | **How often to run a check/remount pass, in seconds.** This is the schedule. |
| `STAT_TIMEOUT`   | `10`    | How long a single mount probe may block before the mount is declared **hung**. |
| `UMOUNT_TIMEOUT` | `10`    | How long a forced `umount -f` may block before falling back to a lazy `umount -l`. |

### Changing the schedule

To check every 30 seconds, or every 5 minutes:

```sh
# every 30 seconds
INTERVAL=30

# every 5 minutes
INTERVAL=300
```

Then `sudo systemctl restart nfs-stale-monitor`.

### Where the config lives

The daemon reads `/etc/nfs-stale-monitor/nfs-stale-monitor.conf` by default.
You can override the location by setting `NFS_STALE_MONITOR_CONF` in the
environment (e.g. in a unit drop-in under `[Service]` → `Environment=`), which
is handy for testing without touching the real file:

```sh
NFS_STALE_MONITOR_CONF=/tmp/my.conf ./nfs-stale-monitor
```

A ready-to-copy template ships in the repo:
[`nfs-stale-monitor.conf.example`](./nfs-stale-monitor.conf.example).

## File layout

| Path | Description |
|------|-------------|
| `nfs-stale-monitor` | The daemon (bash). Installed to `/usr/local/bin/nfs-stale-monitor`. |
| `nfs-stale-monitor.service` | systemd unit. Installed to `/etc/systemd/system/`. |
| `nfs-stale-monitor.conf.example` | Template config. Installed to `/etc/nfs-stale-monitor/nfs-stale-monitor.conf`. |
| `init.sh` | Per-node install/upgrade script. |

## Uninstall

```sh
sudo systemctl disable --now nfs-stale-monitor
sudo rm -f /etc/systemd/system/nfs-stale-monitor.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/nfs-stale-monitor
sudo rm -rf /etc/nfs-stale-monitor
```

## Notes & limitations

- **Remount relies on `/etc/fstab`.** Reclaimed mounts are brought back by
  `mount -a`; make sure your NFS mounts are defined in `/etc/fstab`.
- **NFS only.** Non-NFS mounts are ignored entirely.
- **Stale vs hung.** A *stale* mount (`ESTALE`) and a *hung* mount (blocks past
  `STAT_TIMEOUT`) are both treated the same way and both reclaimed. Tune
  `STAT_TIMEOUT` up if you have a very high-latency NFS server you don't want
  flagged, or down for faster detection.
- **Run on every node.** Each node monitors its *own* local mounts — this is
  intentionally a per-node agent, so the daemon does not need to talk to other
  nodes.
