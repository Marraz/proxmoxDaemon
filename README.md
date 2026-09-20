# nfs-stale-monitor

A small daemon that runs on **each Proxmox node** in a cluster to watch the
node's NFS mounts and automatically recover them when they go stale.

When an NFS server dies or a network path drops, the mountpoints on each node
can turn into *stale* or *hung* handles. Anything that touches them hangs, and
Proxmox storage that lives on NFS becomes unusable. This daemon watches for
that and fixes it on the node where it is running:

1. On a fixed, **configurable interval**, it probes every NFS / NFS4 mountpoint.
2. A mount that no longer responds (hung, or returning `ESTALE` / *"stale file
   handle"*) is **recovered** by detaching it and cycling the owning Proxmox
   storage with the storage manager.
3. Only the affected storage is cycled — healthy mounts are left untouched.

It is deliberately simple and safe: it only ever touches **NFS** mounts, it
recovers each stale mount **independently** (minimal blast radius), and it logs
everything to the journal.

## How it works

- **Source of truth:** NFS mountpoints are read from `/proc/mounts`
  (any fstype starting with `nfs` — `nfs`, `nfs4`, `nfsv4`, …), so it picks up
  whatever the node actually has mounted, regardless of how it was configured.
- **Staleness probe:** each mountpoint is checked with `stat`, wrapped in
  `timeout`. A healthy mount returns in milliseconds. A mount that blocks for
  longer than `STAT_TIMEOUT` seconds is considered **hung**; a `stat` that
  fails (e.g. `ESTALE`) is considered **stale**. Both are recovered.
- **Recovery** (per stale mount, using Proxmox's own storage manager):
  1. `umount -f -l <mountpoint>` — force a lazy unmount to detach the dead
     connection instantly.
  2. `pvesm set <storage_id> --disable 1` — stop the storage.
  3. `pvesm set <storage_id> --disable 0` — re-activate the storage, which
     makes Proxmox re-mount it.
  4. Wait a short, configurable settle period and confirm the mount is healthy
     again.
- **Storage mapping:** the `<mountpoint> → <storage_id>` mapping is read from
  Proxmox's `/etc/pve/storage.cfg` (the `nfs:` entries and their `path`
  lines). No `/etc/fstab` dependency — recovery goes entirely through `pvesm`.

If a stale mount's mountpoint does **not** map to an `nfs:` storage in
`storage.cfg`, the daemon logs a warning and leaves it alone (it will not try
to `pvesm` a storage that doesn't exist) — you'll see it flagged in the journal
every pass so you can deal with it.

## Requirements

- A Proxmox (Debian-based) node, with **root** (the daemon must be able to
  `stat`, `umount`, and run `pvesm`).
- Standard tools: `bash`, `awk`, `stat`, `timeout`, `pvesm` (all present by
  default on Proxmox).
- `systemd` (standard on Proxmox).
- The NFS storages must be declared as `nfs:` entries in
  `/etc/pve/storage.cfg` (the normal way to define NFS datastores in Proxmox).

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

### Running a single pass manually

You can run one check/recover pass and exit (no daemon loop) — handy for
testing or ad-hoc checks:

```sh
nfs-stale-monitor --once
```

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
| `INTERVAL`       | `300`   | **How often to run a check/recover pass, in seconds.** This is the schedule. |
| `STAT_TIMEOUT`   | `10`    | How long a single mount probe may block before the mount is declared **hung**. |
| `UMOUNT_TIMEOUT` | `15`    | How long the forced/lazy `umount -f -l` may block before giving up. |
| `RECOVER_SETTLE` | `5`     | How long (seconds) to poll after re-enabling a storage to confirm it re-mounted. |
| `PVE_SM_TIMEOUT` | `60`    | How long a single `pvesm set` may block before giving up. |
| `STORAGE_CFG`    | `/etc/pve/storage.cfg` | Where the mountpoint → storage-id mapping is read from. |

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

- **Recovery goes through `pvesm`.** Each stale NFS datastore is recovered by
  `umount -f -l` then `pvesm set <id> --disable 1` / `--disable 0`. Only the
  affected storage is cycled, so running guests on other storages are not
  touched.
- **Recovery relies on `storage.cfg`.** The mount must map to an `nfs:` entry
  in `/etc/pve/storage.cfg`. If it doesn't, the daemon flags it in the journal
  and leaves it for manual attention.
- **Stale vs hung.** A *stale* mount (`ESTALE`) and a *hung* mount (blocks past
  `STAT_TIMEOUT`) are both treated the same way and both recovered. Tune
  `STAT_TIMEOUT` up if you have a very high-latency NFS server you don't want
  flagged, or down for faster detection.
- **Run on every node.** Each node monitors and recovers its *own* local mounts
  — this is intentionally a per-node agent, so the daemon does not need to talk
  to other nodes.
