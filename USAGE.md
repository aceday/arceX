# arceX usage

arceX is a minimal Arch-based distribution built by mkosi as a single disk
image. These are the things you actually do with it: install, update, recover.

Quick reference:

| Task | Command |
|---|---|
| Install / flash | `sudo dd if=arcex_<ver>_x86-64.raw of=/dev/disk/by-id/<disk> bs=4M conv=fsync` |
| Download | GitHub Actions artifact in the run / draft release files; verify with `sha256sum -c SHA256SUMS` |
| Update (in place, rescue) | `sudo ace-update /dev/disk/by-id/<disk> arcex_<ver>_x86-64_arcex_usr.raw.zst` |
| Update (staged, next boot) | `sudo ace-update --stage arcex_<ver>_x86-64_arcex_usr.raw.zst [--uki arcex_<ver>_x86-64.efi]` + reboot |
| Boot recovery updater manually | pick "Update arcex" in the GRUB menu (press a key before the 3s timeout) |
| Boot Windows | pick "Boot Windows" in the GRUB menu (chainloads the Windows Boot Manager) |
| Restore arceX as first boot entry | `sudo boot-fix` (after Windows Update reorders NVRAM) |
| Login | user `ace`, password `acex`, then `passwd ace` |

`ace-update` is installed at `/usr/bin/ace-update` on the arceX system (same
script also lives in the repo root as `update.sh` for rescue use).

---

## Downloads

Every non-PR build uploads its images as a **GitHub Actions artifact**; find
them under **Actions → build → `<run>` → Artifacts**. Tag pushes additionally
attach the same files to a draft GitHub Release. The artifact holds:

- `arcex_<ver>_x86-64.raw` — full **flash-ready** image (dd-able as-is),
- `arcex_<ver>_x86-64.raw.zst` — smaller, compressed copy (`zstd -d` first),
- `arcex_<ver>_x86-64_arcex_usr.raw.zst` — split `/usr` partition for
  `ace-update` (update without re-flash),
- `SHA256SUMS` — verify your download: `sha256sum -c SHA256SUMS`,
- the build manifest (`*.manifest.json`).

```console
sha256sum -c SHA256SUMS
zstd -d arcex_<ver>_x86-64.raw.zst                     # or use the .raw as-is
dd if=arcex_<ver>_x86-64.raw of=/dev/block/<DEV> bs=4M conv=fsync
```

GitHub artifact downloads do not support resume and the 500 MB/repo artifact
quota occasionally blocks large images — if an upload fails, the run summary
and the release notes say so, and the fix is to build locally (or re-run CI).

---

## Install

1. Write the raw image onto a target disk. The image is self-contained
   (ESP + `/usr` + root in one GPT layout). Everything is matched by GPT
   label, so the exact device node does not matter:

   ```console
   sudo dd if=arcex_<ver>_x86-64.raw of=/dev/disk/by-id/<disk> bs=4M conv=fsync
   sync
   ```

2. Boot the disk (UEFI). The GRUB menu offers **Boot arcex** (default),
   **Update arcex** (apply a staged update / rescue shell) and **Boot
   Windows** (if a Windows Boot Manager is on the ESP). Every entry falls back
   to the menu with an error if its target is missing, so you can re-select.
   The menu is backed by two UKIs on the ESP:

   - `arcex_<ver>_x86-64.efi` — the normal boot (default).
   - `arcex-recovery.efi` — a tiny recovery initramfs used to apply staged
     updates before booting the installed system.

   `ace-update` is preinstalled on the image (`sudo ace-update --help`).

   GRUB is installed at the UEFI removable-media path
   (`EFI/BOOT/BOOTX64.EFI`), so most firmware finds it with no extra setup.
   If your firmware needs a boot entry, add one pointing at
   `EFI/BOOT/BOOTX64.EFI` on the ESP (`/dev/disk/by-partlabel/arcex-esp`).

3. Root is baked at its final size (it takes whatever is left after ESP +
   `/usr`); no first-boot regrow. Login as `ace`/`acex`.

## Updates

Updates never require a re-flash: only the immutable erofs `/usr` partition
is replaced. `/etc`, `/var` and `/home` (btrfs subvolumes) and the ESP are
left alone, so user data and system state survive updates.

Run one of the two update modes. Both need the artifacts from a build /
release (`ace-update --help` for details):

### A. In-place (from a live/rescue system)

Replaces `/usr` right now, on a disk that is not booted:

```console
sudo ace-update /dev/disk/by-id/<disk> arcex_<ver>_x86-64_arcex_usr.raw.zst [--uki arcex_<ver>_x86-64.efi]
```

The script skips the write when the partition already matches, streams zstd
straight into `dd` (only the used region), and reverifies afterwards.

### B. Staged (from the running system, applies before the next boot)

Copy the artifacts to a location the running system can read (USB stick,
`scp`, …), then stage them:

```console
sudo ace-update --stage arcex_<ver>_x86-64_arcex_usr.raw.zst --uki arcex_<ver>_x86-64.efi
sudo reboot
```

On the next boot GRUB sees the update marker on the ESP
(`/EFI/updates/arcex.update`) and boots the **recovery UKI** instead of the
normal one. The recovery initramfs:

1. mounts the ESP and the root partition (by GPT label),
2. takes the newest staged `/usr` image from `<root>/var/lib/arcex/updates`,
3. writes it onto the `arcex-usr` partition (skipped when it already matches),
4. copies a staged UKI onto the ESP, drops stale ones and regenerates
   `grub.cfg`,
5. clears the marker and reboots into the updated system.

If the update fails, the marker is kept and the next boot retries. Remove the
marker manually to skip an update:

```console
sudo rm /efi/EFI/updates/arcex.update
```

## Recovery

- **Staged update hangs / you want to apply manually**: interrupt GRUB
  (press any key within the 3s timeout) and pick **Update arcex**. The
  recovery shell applies whatever is staged, then reboots.
- **You need a rescue shell**: pick **Update arcex** with nothing staged —
  the minimal initramfs drops you into an emergency shell.
- **Re-flash to roll back**: a full re-flash of a previous image is still the
  last resort. A same-generation re-flash keeps your `/etc`, `/var` and
  `/home` data (they live in btrfs subvolumes that are re-used).

## Installing extra software with nix

The image ships the multi-user nix (`nix-daemon` enabled, `nixbld*` build
users created via sysusers). The store lives at `/nix` on the writable root
partition, so it survives `/usr` erofs updates untouched. Any local account
can use it — no extra group needed:

```console
ace@arcex:~$ nix profile install nixpkgs#google-chrome
ace@arcex:~$ google-chrome
```

`experimental-features = nix-command flakes` is preset
(`/etc/nix/nix.conf`), so `nix profile`, `nix run` and `nix develop` work
directly. Nix is self-contained (its own glibc in the store) and never touches
the read-only `/usr` — the safest way to add software on top of this image.

### KDE Plasma desktop (nix route)

Nothing KDE-related is baked into the image; the desktop is installed per-user
from nixpkgs, so the erofs `/usr` and every future arceX update leave it
untouched:

```console
ace@arcex:~$ sudo -iu ace /usr/lib/arcex/setup-plasma.sh
ace@arcex:~$ exec startplasma-wayland-session     # or: exec startkde
```

The script enables the nix-command/flakes features (already preset in this
image), installs Plasma Desktop + Workspace + KWin + portal + network applet
+ Konsole + Dolphin + Noto fonts + sddm into `~/.nix-profile`, and prints the
start steps. The image ships a gated `sddm.service`
(`/usr/lib/systemd/system/sddm.service`, `ConditionPathExists=…/sddm`) plus an
`sddm` system account, so to boot into the Plasma login screen once installed:

```console
sudo systemctl enable sddm.service
sudo systemctl set-default graphical.target    # then reboot
```

Until sddm exists in the profile the unit is skipped cleanly and boot falls
back to the console login.

## Dual boot with Windows

The GRUB menu ships a **Boot Windows** entry that chainloads the Windows Boot
Manager at `/EFI/Microsoft/Boot/bootmgfw.efi`. One entry covers Windows 8/10/11
installed in UEFI mode (Windows Boot Manager itself shows a picker if several
Windows installs share the ESP). Windows 7 only works here if it was installed
in UEFI mode — a typical MBR/legacy Windows 7 must be booted through the
firmware's own legacy/CSM option instead.

Notes:

- **SecureBoot must be off** for the chainload (arceX has no shim).
- **Make room for Windows first.** arceX ships at `RuntimeSize=13G` (root
  takes the remainder of the disk after ESP + `/usr`). Create/arrange the
  Windows partitions (MSR ~16M, Windows, WinRE ~600M) so arceX fits in the
  space left — there is no first-boot grow to claim free space anymore.
- **Windows Update can reorder UEFI boot order** (or hide entries), so the
  firmware may start Windows — or nothing — before arceX. Fix it from inside
  arceX:
  ```console
  sudo boot-fix          # move the arceX entry to the front
  sudo boot-fix --add    # also create the entry if it was dropped entirely
  sudo boot-fix --dry-run
  ```
  The firmware's own boot menu (e.g. F12) always shows every entry as a
  fallback.
- arceX lives at the removable-media path `EFI/BOOT/BOOTX64.EFI`; `boot-fix`
  matches the entry by the arceX ESP partition UUID + loader path, not by disk
  name.

## Layout reminder

```
p1  esp   vfat  512M   /dev/disk/by-partlabel/arcex-esp   grub, UKIs
p2  usr   erofs 3–8G   /dev/disk/by-partlabel/arcex-usr   mounted at /usr
p3  root  btrfs rest   /dev/disk/by-partlabel/arcex-root   mounted at / (fixed size)

/nix is a plain directory on the btrfs root partition (writable).
```

`/usr` is the **second** partition (immediately before the btrfs root, which is
last) and ships **minimized to its content** per release (mkosi
`Minimize=yes`, `10-usr.conf` floor 3 G, cap 8 G). Updates write the newer
`/usr` image in place; if the payload outgrows the installed partition,
`ace-update` first extends `/usr`'s END into any free gap between it and the
root partition — but because btrfs can only shrink from the disk end (the far
side of `/usr`), the root never yields that gap, so a larger `/usr` normally
means a full re-flash.