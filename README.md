# omarchy-system

A read-only system panel for the Omarchy bar: temperatures, fans, CPU,
memory, disk space, network throughput and power, behind a single bar glyph
tinted green, amber or red.

**Status: early.** The collector and the panel are both verified on three laptops:
a dual-screen laptop with two fans, a fanless laptop, and a single-fan laptop
whose fan is owned by a vendor driver. The fanless, few-sensor and labelled-per-core paths
all have real hardware behind them, and each of the two machines added after the
first has changed the code: see below.

```bash
omarchy plugin add https://github.com/brightwalker25/omarchy-system.git
omarchy plugin enable brightwalker25.system --section right
```

The collector ships inside the plugin and is found relative to it, so there is
no symlink or PATH step.

## Design

A collector script prints one normalised JSON snapshot; the QML panel renders it
and does no discovery of its own. This is the same shape Omarchy uses for its own
agent-usage widget, and it means every machine-specific quirk lives in one
testable file that runs fine from a terminal.

The collector is **stateless and instantaneous**. Cumulative counters (network
bytes, `/proc/stat` jiffies) are emitted raw next to a monotonic timestamp, and
the panel takes deltas between polls to derive rates. Nothing sleeps, nothing
shells out: one poll is a single pass over sysfs, taking ~46 ms and ~4.9 KB on the
dual-screen laptop, ~200 ms and ~3.2 KB on the fanless one, whose low-power CPU
is the slower part by some way and whose five hwmon chips are half the
dual-screen laptop's sensor count.

### Two headline temperatures, not one

The hottest sensor in a machine and the sensor closest to its own limit are
usually not the same sensor, so the collector reports both and leaves the choice
to the panel. On the dual-screen laptop the SSD sits at 62% of its 84.8 °C crit while the
CPU package and the wifi chip both read several degrees hotter against a 100 °C
crit and no crit at all respectively. Picking either one alone hides the other.

- `thermal.hottest`: highest reading in the box, from either class.
- `thermal.closestToLimit`: governed sensor with the least headroom left.
  Absent when nothing publishes a threshold.

On the fanless laptop the two are the same sensor. With no fan and one dominant heat
source, whichever of the CPU package and the NVMe leads leads on both counts at
once, so the panel would spend a caption line restating the row directly above
it. When the two coincide the panel folds them into one caption carrying the
limit; the collector still emits both, because which machine it is running on is
not something it should have to know.

### Used and free, as figures and as shares

A percentage on its own does not say whether 8% free is 30 GB or 300 MB, and a
figure on its own does not say whether 30 GB is comfortable. The panel gives
both for each side: how much is used out of the total, then how much is free
with each side's share of the whole.

Those two shares do not add up to 100%, and the panel says why rather than
fudging one of them. `freeBytes` is what an unprivileged process can actually
write (`f_bavail`), not what is unallocated; the difference is the reserved
blocks, emitted as `reservedBytes` and shown as their own line when they are
large enough to make the arithmetic look wrong.

Inode exhaustion fills a filesystem that still reports free bytes, so
`inodesUsedFraction` is emitted where the filesystem accounts for inodes at
all (btrfs and xfs allocate them dynamically and report none) and the panel
mentions it only once it is close enough to matter.

### One row per filesystem, not per mount

A mount is included when its source stats as a block device. That is a
discovered property rather than a list of filesystem names, so btrfs, ext4,
xfs and f2fs all arrive without being named in code, while tmpfs, proc,
cgroup, overlay and the rest do not: none of them has a device behind it.
Network mounts are excluded by the same rule, which is just as well, since
`statvfs` on a dead NFS server blocks and this runs on a timer behind a bar
panel.

Filesystems are keyed on the block device rather than on the mountpoint,
because one filesystem is very often mounted several times. A btrfs root
subvolume layout puts `/`, `/home`, `/var/log` and `/var/cache/pacman/pkg` on
one device, and every one of them reports the same pool-wide free space;
listing four identical rows would say four times over what is true once. The
mountpoint kept is `/` where the device holds it and the shortest path
otherwise, and bind mounts collapse under the same rule.

Each filesystem also carries the physical drive it ultimately sits on, found
by following sysfs rather than by trimming digits off a device name: a
partition through its parent directory, and a LUKS or LVM mapping through
`slaves/`, which for an encrypted volume on a partition is two hops. That is
what lets a filesystem be put next to the temperature of the drive holding
it, and for `/dev/mapper/...` it is not the device the filesystem is mounted
from.

### Portability

Targets laptops with very different sensors, so nothing is hardcoded:

- Sensors are **discovered** by walking `/sys/class/hwmon`. No sensor is ever
  named in code (`TPCD` is meaningless outside an Apple SMC).
- Labels come from sysfs `*_label` files, so **lm_sensors is not a dependency**.
- Attributes are read from the hwmon directory *and* its `device` target, since
  drivers on the older hwmon API expose nothing in the hwmon directory itself
  and a naive walk finds none of their sensors.
- Disk temperatures are looked for both directly under the device
  (`device/hwmon3`, which is what NVMe gives) and inside a `hwmon/` container.
- Published thresholds above 200 °C are discarded. NVMe reports an unset
  threshold as 0xFFFF Kelvin, which arrives as 65261.85 °C.
- Temperatures split into two classes, because the hardware is not consistent:
  **governed** sensors publish a crit threshold, so `headroomC` and
  `critFraction` are real figures, while **ambient** sensors publish none and
  can only honestly show a raw reading. Four of the dual-screen laptop's twenty
  sensors are ambient, including `acpitz` and the wifi chip. The fanless laptop
  has no `acpitz` hwmon at all; it exposes `coretemp`, `nvme` and `iwlwifi_1`
  and nothing else, so its one ambient sensor out of eleven is the wifi chip.
  The single-fan laptop has an `acpitz` and it publishes no threshold either, so
  that is ordinary rather than particular to one machine.
- Sensor ids carry the device the chip hangs off when a chip name repeats
  (`nvme/nvme0/temp1`), because two NVMe drives register two chips both called
  `nvme` and `nvme/temp1` would otherwise name a sensor on each. The device
  basename is used rather than the hwmon number, which depends on probe order.
  Where a chip name is already unique the id is just `chip/attr`.
- An empty fan list is explained rather than left to speak for itself, because
  `fans: []` means two different things. The fanless laptop has no fan;
  the single-fan laptop has one that a vendor driver owns over an ioctl and no
  hwmon publishes. `fanReporting` says which was found: `reported`, `declared` (an
  ACPI `PNP0C0B` device or a `Fan` cooling device, but no readable speed),
  `vendor` (a driver known to own fans out of band), or `none`. That way the panel
  can say "no fan" on one machine and "fan present, no driver reporting speed"
  on the other. Nothing here names a machine, and an unrecognised case is left
  unsaid rather than guessed.
- Block devices reporting zero sectors are skipped. An empty SD card reader is
  still a block device, and the fanless laptop listed two phantom drives with no size
  and no temperature. The filter is on size rather than on a name prefix, so the
  reader appears again once it actually holds a card.
- Filesystems are found through mounts whose source is a block device, so no
  filesystem type is ever named in code, and they are deduplicated by device
  so that several mounts of one filesystem are one row. See above.
- Drive capacity and filesystem capacity are kept apart. A drive's size is the
  hardware's, before any partitioning, and its temperature belongs to the
  drive; how full a filesystem is is a different question with a different
  answer.
- Battery watts are tagged `wattsDirection`, since the same reading is draw when
  discharging and charge rate when charging.
- Peripherals that register as batteries (a stylus, a wireless keyboard) are
  skipped. They report `scope=Device` and would otherwise show as extra
  batteries stuck at 0%.

## Usage

```bash
bin/system-collect          # compact JSON, one line
bin/system-collect --dump   # indented, for reading
```

Requires Python 3 and a Linux `/sys`. Nothing else.

### Settings

| Setting | Default | What it does |
|---|---|---|
| `refreshIntervalMs` | 2000 | How often the collector runs while the panel is open |
| `barRefreshIntervalMs` | 60000 | How often the collector runs for the bar colour while the panel is closed, at least 15 seconds |
| `perCoreCutoff` | 8 | Above this thread count the per-core bars become a compact strip |
| `maxSensorRows` | 4 | Temperature rows before the rest are summarised in one line |
| `maxFilesystemRows` | 4 | Filesystem rows, root first and then the fullest, before the rest are summarised |
| `diskAlarmPercent` | 90 | How full a filesystem has to be before its bar takes the urgent colour |

A new machine is worth capturing with `bin/system-collect` before assuming its
sensors look like anything already seen.

## Acknowledgements

The bar widget and parts of the panel are derived from Omarchy's own shell
plugins, which are MIT licensed: Copyright (c) David Heinemeier Hansson,
https://github.com/basecamp/omarchy. The weather plugin in particular is the
model this was built from; its author is the Omarchy project itself rather than
a separate third party.

- `BarWidget.qml` follows `omarchy.weather`'s bar widget closely. The
  injectPanel / open / close / closeForPopoutSwitch contract is what the bar
  requires of any widget that hosts a panel, and 43 of this file's 49
  non-comment lines are identical to it. This is a derivative of that file
  rather than something merely inspired by it.
- The panel's `Meter` component, its colour bindings and its IPC scaffolding
  come from `omarchy.agents`.
- The collector's shape (a script that prints one JSON snapshot, with the QML
  rendering it and discovering nothing itself) follows `omarchy-agent-usage-*`.

Omarchy's copyright and permission notice is reproduced in `LICENSE`.

## Written with AI help

Yes, an AI helped write this. No, it is not Skynet. Or is it? Either way, I
have checked the code to make sure it is not plotting Judgment Day. If that
still puts you off, no hard feelings. The whole point of Linux is that you
decide what runs on your computer.

## Licence

MIT
