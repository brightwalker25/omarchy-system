# Changelog

## 0.2.1

### Changed

- The bar glyph is now tinted green, amber or red. While the panel is closed
  the collector runs once a minute (`barRefreshIntervalMs`, default 60000) to
  keep the tint honest. Red is what the panel already alarms on: a sensor at
  90% of its critical limit, a filesystem past `diskAlarmPercent`, under 5%
  of memory available, or a battery at 15% and not charging. Amber is the
  approach to each (80%, five points short, under 10%, 25%), or a collector
  that could not be read.

## 0.2.0

### Added

- **A Storage section.** Every real filesystem gets its used figure against
  the total, a bar, and then the used and free shares as percentages beside
  the free figure. Both numbers and both percentages, because neither answers
  the question on its own.
- Drives are listed under the filesystems with their capacity, whether they
  are solid state or spinning, and their temperature where the drive
  publishes one. A drive's capacity is the hardware's, before partitioning,
  which is a different question from how full a filesystem is.
- `filesystems` in the collector's output, with `sizeBytes`, `usedBytes`,
  `freeBytes`, `reservedBytes`, `usedFraction`, `freeFraction`, the mountpoint,
  the filesystem type, the source device, the block device, and the physical
  disk the whole thing sits on.
- Inode figures where the filesystem accounts for them, since inode
  exhaustion fills a filesystem that still reports free bytes. Shown on the
  panel only from 80% used.
- Two settings: `maxFilesystemRows` (default 4) and `diskAlarmPercent`
  (default 90).

### Notes on the approach

- A mount is included when its source stats as a block device, so no
  filesystem type is named in code and tmpfs, proc, cgroup and overlay are
  excluded by what they are rather than by a list. Network mounts are
  excluded too, which also avoids a `statvfs` that blocks on a dead server.
- Filesystems are keyed on the block device, not the mountpoint. A btrfs
  subvolume layout mounts one filesystem at `/`, `/home`, `/var/log` and
  `/var/cache/pacman/pkg`, all reporting the same pool-wide free space; that
  is one row, not four. Bind mounts collapse the same way.
- `usedBytes` and `freeBytes` do not sum to `sizeBytes`. Free is what an
  unprivileged process can write; the reserved blocks are emitted separately
  rather than folded into either side, and the panel shows them when they are
  big enough to make the percentages look wrong.
- The disk a filesystem sits on is found through sysfs, a partition through
  its parent and a LUKS or LVM mapping through `slaves/`, so an encrypted
  volume resolves to the physical drive in two hops rather than by guessing
  at device names.

The schema version stays at 2. The change is additive, and a consumer that
wants the new data can test for the key.

## 0.1.0

First working version. Collector and panel for thermals, load, network and
power, verified on three laptops: a dual-screen laptop, a fanless laptop and a
single-fan laptop.
