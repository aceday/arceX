# arceX — Arch Linux image built with mkosi

arceX is a minimal, fast-reflash Arch-based distribution built as a **single
disk image** by [mkosi](https://github.com/systemd/mkosi):

- **Base**: Arch Linux from the CachyOS repos, kernel = `linux-cachyos`.
- **Single image**: one `Format=disk` raw image containing everything —
  ESP + `/usr` + root. Built once, deployed by `dd`-ing it onto a disk.
- **Immutable `/usr`**: a read-only **erofs** partition (zstd-compressed),
  mounted via `systemd-dissect`. Writable at runtime with `rw` but the mount is
  volatile — every change to `/usr` resets on reboot.
- **Writable root**: a **btrfs** partition with subvolumes `/etc`, `/var`,
  `/home` (persistent, no-cow for `/nix`), baked at its final size (it takes
  the remainder of the disk after ESP + `/usr`).
- **Boot**: GRUB with an **unsigned** unified kernel image (UKI). A second,
  minimal **recovery UKI** (`arcex-recovery.efi`) applies staged updates
  before the running system boots. No SecureBoot, no dm-verity, no A/B slots
  — rollback means re-flashing a previous image.
- **Updates**: OS userspace updates are flashed **in place onto the `/usr`
  partition only** via `update.sh` (no re-flash; `/etc`/`/var`/`/home` and ESP
  untouched), either immediately from a live system or **staged** from the
  running system and applied by the recovery UKI on the next boot. Kernel/UKI
  changes sync to the ESP with `--uki`; a full re-flash remains the last
  resort for partition-layout changes.
- **Build/publish**: a single `mkosi build` in GitHub Actions (privileged
  CachyOS container), summarized to a `.manifest.json`, artifacts attach to a
  GitHub release on tag pushes.

---

## Design decisions

| Question | Decision | Rationale |
|---|---|---|
| Base | Arch via mkosi, CachyOS repos | Reuse mkosi instead of hand-rolled pacstrap+partitioning. |
| Root format | btrfs, writable | Simple, no hashing infrastructure; state survives re-flash via grow + subvolumes. |
| `/usr` format | erofs (zstd), `mount.usr=dissect` | Immutable package set, compressed; mounted by systemd at boot. |
| Bootloader | GRUB + unsigned UKIs + recovery UKI | UKIs embed kernel+initrd+cmdline; GRUB chainloads one UKI per kernel and a dedicated one for staged pre-boot updates. |
| Update policy | Re-flash whole image | "too slow to deploy" was the old blocker; one dd replaces the OTA/A-B machinery. |
| Overlay/verity/A-B | none | Dropped; rollback = keep the previous image + re-flash. |
| State | btrfs subvolumes `/etc` `/var` `/home` | Grown partition keeps subvolume data across re-flashes/growth. |
| Container repo keyring | host `/usr/share/pacman/keyrings` sandboxed in | mkosi ToolsTree sandbox uses the host's initialized keyring instead of re-running pacman-key. |

## Partition layout (the raw image, `mkosi.repart/`)

```
p1  esp   vfat  512M   GRUB, /EFI, /BOOT copy, UKIs (incl. recovery UKI)
p2  usr   erofs 3–8G   mounted at /usr (read-only, zstd-compressed; minimized
                       to its content per release)
p3  root  btrfs rest   mounted at /  (subvolumes /etc /var /home, /nix nodatacow;
                       SizeMinBytes=1G, takes the remainder of the disk)
```

Produced by:
- `mkosi.repart/00-esp.conf` — ESP vfat 512M, `Label=arcex-esp`:
  `CopyFiles=/efi:/` + `/boot:/`.
- `mkosi.repart/10-usr.conf` — `Type=usr`, `Format=erofs`, `Label=arcex-usr`,
  `SizeMinBytes=3G` / `SizeMaxBytes=8G`, `Minimize=yes` (squeezes the erofs to
  its real content), `Compression=zstd`, `SplitName=_arcex_usr` (write-out the
  partition image).
- `mkosi.repart/20-root.conf` — `Type=root`, `Format=btrfs`, `Label=arcex-root`,
  `CopyFiles=/:/` minus `/usr`, `MakeDirectories=/var /var/lib/extensions /nix
  /home`, `Subvolumes=/etc /var /nix:nodatacow /home`, `SizeMinBytes=1G`.

Partitions are matched by type/name/label (`arcex-usr`, `arcex-root`), not by
number. `/usr` is the **second** partition, immediately before the btrfs root
(`/root` is last). Because btrfs can only shrink from its end (the disk tail,
on the far side of `/usr`), `/usr` cannot reclaim root space in place: the only
room it has to grow into is whatever free gap sits between it and the root
partition at flash time. In practice that gap is empty (root is laid down
flush after `/usr`), so a larger `/usr` normally means a **re-flash**; the
pre-boot recovery updater still tries the gap first and gives a clear message
when it cannot grow. Bump `SizeMaxBytes` in `10-usr.conf` if future content
grows beyond 8G, or relocate `/usr` to the last position again if reclaimable
in-place growth is needed.

## Boot flow

1. UEFI firmware runs the GRUB core at `EFI/BOOT/BOOTX64.EFI` (removable-media
   path; a UEFI boot entry can point there instead). GRUB loads
   `/grub/grub.cfg` from the ESP.
2. `/grub/grub.cfg` is the arceX GRUB menu (Boot arcex / Update arcex /
   Boot Windows), emitted from the static template in
   `mkosi.extra/efi/grub/grub.cfg`. The image finalize step regenerates it via
   `write-grub-cfg.sh`, which discards the per-version entry mkosi appends to
   the seed; `update-recovery.sh` regenerates the same way on device, so the
   config on the ESP is always byte-identical to the template. Policy:
   - **Boot arcex** (default): globs `/EFI/Linux/arcex_*_x86-64.efi` for the
     newest UKI and chainloads it (3s GRUB menu).
   - **Update arcex**: chainloads the recovery UKI; the recovery initramfs
     applies any staged update, then reboots.
   - **Boot Windows**: chainloads `/EFI/Microsoft/Boot/bootmgfw.efi` when a
     Windows Boot Manager is on the ESP (Windows 8/10/11; Windows 7 only in
     UEFI mode).
   - **staged update**: if the marker `/EFI/updates/arcex.update` exists on
     the ESP, GRUB boots `arcex-recovery.efi` (default index 1, timeout 0) so
     the staged `/usr` update is applied **before** the running system boots.
   - every entry checks for its target first and prints an error + returns to
     the menu if it is missing, so a failed selection can be re-tried.
3. Normal boot: kernel cmdline `root=dissect mount.usr=dissect rw audit=0` —
   systemd opens the image with `systemd-dissect` and mounts `/` (btrfs) +
   `/usr` (erofs).
4. First boot: root is already at its final size — there is no regrow step.
   A later update that ends up with a larger `/usr` grows *that* partition in
   place (see "Update / deployment model").
5. `systemd-sysext` (if enabled) merges optional extension images from
   `/var/lib/extensions/`.
6. Normal Arch network stack: NetworkManager + systemd-resolved + timesyncd +
   fstrim.timer (enabled by `mkosi.postinst.chroot` preset `90-arcex.preset`).

## Recovery / staged update flow

The image ships a second UKI, `arcex-recovery.efi` (kernel + a minimal
systemd initramfs, cmdline `arcex.update`), built in `mkosi.postinst.chroot`
with `systemd-ukify` + the `systemd-stub` (same tooling mkosi uses for the
main UKI). Its initramfs is produced by mkinitcpio from a dedicated
config/hook (`mkosi.extra/etc/initcpio/arcex-update.conf` + install hook)
and contains `arcex-update-recovery.service`, gated on
`ConditionKernelCommandLine=arcex.update`.

When the GRUB marker is set (by `update.sh --stage`), that service runs in
the recovery initramfs and:

1. mounts the ESP (label `arcex-esp`) and the root partition (`arcex-root`)
   by GPT label — GRUB itself never writes to disk, the initrd does,
2. picks the newest `/usr` image staged in `<root>/var/lib/arcex/updates`,
3. writes it onto `arcex-usr` only when it differs (streamed zstd → dd,
   then re-hashes to verify); if the payload is **larger** than the installed
   partition it first grows `/usr` — extending its END into the free gap
   between `/usr` and the root partition (`sgdisk`; root data is never
   touched, because btrfs can only shrink from the disk end which is the far
   side of `/usr`), aborting with a clear "re-flash a larger /usr" message
   when that gap is empty (the usual case),
4. installs a staged UKI (same version prefix) onto the ESP, removes stale
   ones and regenerates `grub.cfg` via
   `mkosi.extra/usr/lib/arcex/write-grub-cfg.sh`,
5. clears the marker and reboots (a failing update keeps the marker so the
   next boot retries).

## Update / deployment model

- **Fast path — in-place `/usr` update**: `./update.sh <disk> <usr-image>`.
  The build produces a **split `/usr` partition image**
  (`mkosi.output/arcex_<ver>_<arch>_arcex_usr.raw`, zstd-compressed by CI via
  `SplitArtifacts=uki,partitions` + `SplitName=_arcex_usr` in `10-usr.conf`).
  The script finds the `arcex-usr` partition by GPT label, refuses mounted /
  booted disks, **skips the write when a hash match shows the partition is
  already current**, streams zstd straight into `dd` only the used region (the
  minimized partition is all used - nothing blank is rewritten), then re-hashes
  to verify. Only the read-only erofs `/usr` partition is touched — `/etc`
  `/var` `/home` (btrfs) and the ESP stay put, so normal package updates never
  require a re-flash. Kernel changes are the exception: pass
  `--uki <arcex_<ver>_<arch>.efi>` to also copy the new UKI onto the ESP.
- **Pre-boot staged update**: from the running system,
  `./update.sh --stage <usr-image> [--uki <uki>]` copies the artifacts into
  `<root>/var/lib/arcex/updates` and arms the ESP marker; the next boot's
  recovery UKI applies them automatically (see above). Only the `/usr`
  content and, when a new kernel is included, its UKI change — no re-flash.
- **Full re-flash**: `dd if=arcex_<ver>_x86-64.raw of=/dev/disk/by-id/<disk>` (the
  CI artifact) — needed only when a newer `/usr` can't be grown (disk too full)
  or for a clean install. Because root keeps its fixed size and data lives in
  `/etc`/`/var`/`/home` btrfs subvolumes, a same-generation re-flash keeps your
  data.
- **Optional sysexts**: drop erofs extension images into `/var/lib/extensions/`
  with a matching `extension-release` so `systemd-sysext` merges them.

## Build pipeline (GitHub Actions) — `.github/workflows/build.yml`

`workflow_dispatch` (input: `version`) or a `v*` tag push → single `build` job
in a **privileged `cachyos/cachyos-v3:latest`** container (privileged so mkosi's
sandbox + repart can work):

1. resolve version (tag name > input > `date +%Y.%m.%d`).
2. pacman-key init/populate `cachyos`; install `mkosi systemd-ukify erofs-utils
   btrfs-progs dosfstools mtools squashfs-tools cpio jq git`.
3. `mkosi --image-version=<ver> build` → `mkosi.output/arcex_<ver>_x86-64.raw`
   (+ `.manifest.json`) plus the split `/usr` partition image
   `arcex_<ver>_x86-64_arcex_usr.raw` for `update.sh`.
4. zstd-compress the raw images (non-PR runs), upload the `mkosi.output`
   artifact.

`release` job (tag pushes only): downloads the run artifact and attaches the
images to a **draft GitHub Release** (with `SHA256SUMS`). If the artifact
upload was blocked by the 500 MB/repo artifact quota, the release notes say so
instead of shipping nothing. No signing — artifacts stay in the repo's Actions
storage.

No secrets/signing are needed.

## On-device layout (from `mkosi.extra/` + postinst)

```
mkosi.sandbox/etc/pacman.conf   repo config for the build sandbox (cachyos +
                                arch core/extra via host mirrorlists)
mkosi.extra/efi/grub/grub.cfg   GRUB menu template: Boot/Update/Boot Windows
                                entries, per-entry not-found error handling,
                                staged-update marker logic
mkosi.extra/usr/lib/arcex/update-recovery.sh       recovery applier (runs in initrd)
mkosi.extra/usr/lib/arcex/write-grub-cfg.sh        emits the GRUB menu; regenerates
                                                   grub.cfg after a UKI change or in
                                                   the image finalize step
mkosi.extra/usr/lib/arcex/boot-fix.sh             restores arceX as first UEFI boot
                                                   entry via efibootmgr (Windows
                                                   Update can reorder NVRAM);
                                                   /usr/bin/boot-fix -> ../lib/arcex/boot-fix.sh
mkosi.extra/usr/lib/systemd/system/arcex-update-recovery.service  gated on arcex.update cmdline
mkosi.extra/etc/initcpio/arcex-update.conf         mkinitcpio config for the recovery initramfs
mkosi.extra/etc/initcpio/install/arcex-update      mkinitcpio hook pulling the tooling/binaries
mkosi.postinst.chroot           writes 90-arcex.preset (NetworkManager,
                                systemd-resolved, systemd-timesyncd, fstrim.timer
                                on; systemd-networkd off) + /var/lib/extensions;
                                creates user `ace` (wheel/sudo) + log dirs; builds
                                the recovery initramfs/UKI (mkinitcpio + ukify)
mkosi.finalize                  regenerate the GRUB menu via write-grub-cfg.sh
```

## Milestones → status

1. Repo skeleton + design doc — done
2. Drop legacy squashfs/verity/GRUB/A-B/OTA pipeline — done
3. mkosi.conf + sandbox pacman — done
4. repart partitions (esp/usr/root) — done
5. extra firt-boot grow + sysext drop-in — done
6. postinst/finalize presets — done
7. CI workflow rewrite (privileged cachyos container) — done
8. Bootloader GRUB + recovery UKI (staged pre-boot updates) — done
9. First full CI build pass — **next**
10. `dd` image + boot on hardware (X390) — **next**
11. Optional: sysext layer signing / SecureBoot UKI — later

## Notes / knowns

- Default user: `ace` / password `acex`, shell bash, home `/home/ace`,
  member of `wheel`; sudo granted via `/etc/sudoers.d/10-arcex-wheel`
  (`%wheel ALL=(ALL:ALL) ALL`). Created in `mkosi.postinst.chroot`
  (`shadow` added to `Packages` for `useradd`/`chpasswd`). Root is locked —
  admin via `sudo`. Change the password on first boot: `passwd ace`.
- UKIs are unsigned; SecureBoot (via `sbctl`) and sysext signing are a later
  hardening step.