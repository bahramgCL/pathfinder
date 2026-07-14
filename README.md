# exFAT Superfloppy Recovery

Safely recover data from a **partitionless ("superfloppy") exFAT disk** whose boot-region
checksum has been corrupted, so Windows shows it as *unallocated* and Linux refuses to
mount it (`dmesg`: `Invalid boot checksum ... invalid boot region ... failed to recognize
exfat type`).

This is the situation you get when a disk is formatted exFAT *without a partition table*
(a raw filesystem written straight to the whole disk) and later isn't cleanly unmounted.
The data is almost always intact — only the small boot-region header is inconsistent — but
neither Windows nor Linux will mount it until the header is repaired, and repairing it
means *writing to the disk*, which is exactly what you don't want to do to the only copy of
important data.

## How it works (and why it's safe)

The source disk is **never written to.** The script stacks a Linux device-mapper
*snapshot* in front of it:

- **Reads** fall through to the physical disk.
- **Writes** divert into a small copy-on-write (COW) overlay file on the destination.

The boot-region repair (`fsck.exfat`) is run against the *snapshot*, so the fix lands in
the overlay file, not on the disk. The repaired snapshot is then mounted **read-only** and
the data is copied off with `rsync`. When you're done, the physical source disk is
byte-for-byte identical to how it started.

```
  physical source disk (read-only, untouched)
            │  reads fall through
            ▼
     ┌──────────────┐        writes (the boot-region fix)
     │  dm-snapshot │ ─────────────────────────────►  overlay.img on destination
     └──────────────┘
            │  mounted read-only
            ▼
      rsync ──► destination NTFS disk
```

## Requirements

**On the machine:**
- Windows 10/11 with **WSL2** and a Linux distro installed (tested on Ubuntu 24.04).
- The recovery runs *inside WSL*; the Windows steps run in an **Administrator** PowerShell.

**A destination disk:**
- Must be **NTFS-formatted** and have at least as much free space as the source holds.
- NTFS is journaled and native to Windows, and it avoids re-creating the very
  partitionless-exFAT problem you're recovering from.

**WSL check (do this in advance, not mid-recovery):**
```powershell
wsl --list --verbose
```
You want at least one distro at **VERSION 2**. If you have none, or WSL isn't installed:
```powershell
wsl --install
```
...then reboot. `wsl --mount` only works with WSL2 — a WSL1 distro will fail with
`WSL_E_WSL2_NEEDED` (convert with `wsl --set-version <Distro> 2`).

The Linux packages the script needs (`exfatprogs`, `util-linux`, `dmsetup`, `rsync`) are
checked at startup and it offers to `apt install` any that are missing.

## Usage — the three phases

The recovery straddles two environments: Windows (PowerShell) attaches the disk to WSL, the
script (bash, inside WSL) does the repair and copy, and Windows detaches it at the end.

### Phase 1 — Windows: attach the disk to WSL

Open **Terminal (Admin)** / **PowerShell (Admin)** (right-click Start).

Identify the source disk — the ~unallocated one of the right size:
```powershell
Get-Disk | Format-Table Number,FriendlyName,PartitionStyle,@{N="SizeGB";E={[math]::Round($_.Size/1GB,1)}}
```
Note its **Number** (call it `<N>`), then take it offline and attach it raw:
```powershell
Set-Disk -Number <N> -IsOffline $true
wsl --mount \\.\PHYSICALDRIVE<N> --bare
```
> Taking it offline stops Windows and WSL from fighting over the disk. `--bare` attaches
> the raw device without Windows trying to interpret the (missing) partition table.

### Phase 2 — WSL: run the script

Enter WSL:
```powershell
wsl
```
Go to wherever the script is saved and run it. Files on your C: drive appear under
`/mnt/c/` inside WSL:
```bash
cd /mnt/c/Users/<you>/Downloads     # or wherever you put it
chmod +x exfat-superfloppy-recover.sh   # only needed the first time
sudo ./exfat-superfloppy-recover.sh
```
The script will:
1. Check required tools (offer to install missing ones).
2. **Auto-scan** for exFAT-superfloppy source disks and present a numbered menu.
3. **List** candidate NTFS/Windows destinations as a numbered menu.
4. Make you confirm the source (`YES`) and that the destination is NTFS (`NTFS`).
5. Build the read-only snapshot overlay and repair the boot region *on the snapshot*.
6. Mount read-only, check capacity, copy with `rsync`, then verify.
7. Print the Phase 3 teardown commands.

Nothing destructive happens without an explicit typed confirmation, and the source is
never written to on any path.

### Phase 3 — Windows: detach the disk

Back in the **Administrator** PowerShell, run what the script printed (`<N>` is the same
disk number from Phase 1):
```powershell
wsl --unmount \\.\PHYSICALDRIVE<N>
Set-Disk -Number <N> -IsOffline $false
```
The source disk comes back Online in Windows, unchanged — it will still show as
unallocated/partitionless, because we deliberately never modified it.

## The one decision point: the `fsck` result

The script pauses conceptually at the filesystem check, because this is where "routine" and
"call for help" diverge:

- **`fsck` reports the volume is `clean`** (after restoring the boot region) → this is the
  expected case. It really was just the boot checksum; your files are intact. The script
  continues automatically.
- **`fsck` cannot fully repair** (exit code ≥ 4, or it reports remaining errors) → the
  script **stops**. This means there's damage beyond a boot checksum — a bad FAT, a broken
  directory tree — and blindly continuing could produce a corrupt copy. **The source is
  untouched.** Get someone who understands filesystems to look before going further; the
  right next move is usually a full `ddrescue` image to a separate disk and recovery from
  the image.

## After a successful run

You now have **two copies**: the recovered data on the NTFS destination, and the original
source disk, unchanged.

- The COW overlay file (`.cow_<timestamp>.img` on the destination) is deleted automatically
  unless you choose to keep it. It only ever held the boot-region fix.
- To make the *source* disk normally usable again, and only after you've confirmed the copy
  is good: initialize it as GPT and format it NTFS in Windows Disk Management. There is no
  safe in-place fix — a partition table would overwrite the exFAT boot region — so it's
  copy-off, verify, then reformat.

## Verifying the copy

The script runs a **fast check** automatically (every file present, matching size and
mtime — prints nothing if all match) and offers an optional **full checksum verify**
(re-reads every byte on both sides; slow but definitive). For irreplaceable data, running
the full verify at least once is worthwhile.

## Troubleshooting

**`WSL_E_WSL2_NEEDED` when mounting** — your distro is WSL1. Convert it:
`wsl --set-version <Distro> 2`, then retry Phase 1's `wsl --mount`.

**`$'\r': command not found` or other `\r` errors** — the script picked up Windows
(CRLF) line endings, usually from editing it in a Windows editor. Fix inside WSL:
```bash
sed -i 's/\r$//' exfat-superfloppy-recover.sh
```
Cloning the repo *inside* WSL avoids this entirely.

**Source disk not in the menu** — it isn't attached yet. Re-check Phase 1: the disk must be
offline in Windows (`Set-Disk ... -IsOffline $true`) *and* attached (`wsl --mount ... --bare`).
Run `lsblk` in WSL to confirm it appears (it'll be the large device with no partition under it).

**`blkid` says `PTTYPE="dos"` instead of exFAT** — this is a known false positive on
superfloppies (the exFAT boot sector ends with the same `0x55AA` signature as an MBR). The
script checks the `EXFAT` signature at byte offset 3 directly, which is authoritative, so
this doesn't matter.

**`fsck.exfat: command not found`** — the `exfatprogs` package isn't installed. The script
offers to install it at startup; if you skipped that, run
`sudo apt update && sudo apt install -y exfatprogs`.

**Long transfers / disconnects** — for a full-disk copy (hours), run the script inside
`tmux` so it survives a closed terminal: `sudo apt install -y tmux`, `tmux new -s recover`,
run the script, detach with **Ctrl+B** then **D**, reattach later with `tmux attach -t recover`.
`rsync` is resumable, so an interrupted copy continues where it left off on re-run.

## Safety summary

- The physical source disk is **never written to** — repair and mount only ever target the
  snapshot device.
- The read-only mount is **verified** after mounting; the script aborts if it isn't `ro`.
- Source and destination are chosen from validated menus, with typed confirmations, and the
  destination cannot be on the source disk.
- On any exit — success, error, or Ctrl+C — the snapshot, loop device, and mount are torn
  down automatically, so nothing is left dangling.

Use at your own risk. Always verify your copy before trusting it or reformatting the source.

## License

MIT — see [LICENSE](LICENSE).
