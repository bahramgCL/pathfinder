#!/usr/bin/env bash
#
# exfat-superfloppy-recover.sh
# ----------------------------------------------------------------------------
# Safely recover data from a partitionless ("superfloppy") exFAT disk whose
# boot-region checksum is corrupt, so the kernel/FUSE exFAT drivers refuse to
# mount it (dmesg: "Invalid boot checksum ... invalid boot region ...").
#
# HOW IT STAYS SAFE
#   The source disk is NEVER written to. We stack a device-mapper "snapshot"
#   in front of it: reads fall through to the physical disk, writes divert to a
#   small copy-on-write (COW) overlay file on the destination. fsck's boot-region
#   repair therefore lands in the overlay, not on the source. We then mount the
#   *repaired snapshot* strictly read-only and rsync the data to the destination.
#   The physical source ends byte-for-byte identical to how it started.
#
# WHAT THIS SCRIPT DOES NOT DO
#   - It does not touch the Windows side. Before running, the source disk must
#     already be offline in Windows and attached raw to WSL2. Commands for that
#     are printed if the source device isn't found (see PREREQUISITES below).
#   - It never runs fsck or a rw-mount against the raw source device. Only the
#     snapshot device is ever repaired or mounted.
#
# PREREQUISITES (run in an *Administrator* PowerShell, once per source disk):
#     Get-Disk | Format-Table Number,FriendlyName,PartitionStyle,`
#         @{N="SizeGB";E={[math]::Round($_.Size/1GB,1)}}
#     Set-Disk -Number <N> -IsOffline $true
#     wsl --mount \\.\PHYSICALDRIVE<N> --bare
#   ...then run this script inside WSL. Teardown PowerShell commands are printed
#   at the end.
#
# USAGE
#     sudo ./exfat-superfloppy-recover.sh
#   You will be prompted for the source device and destination path, and asked
#   to confirm the destination is NTFS. Nothing destructive happens without an
#   explicit typed confirmation.
#
# REQUIREMENTS (Linux side): exfatprogs, util-linux (losetup, blockdev),
#   dmsetup (dmsetup), rsync, coreutils. The script offers to apt-install any
#   that are missing.
#
# Tested on: WSL2 Ubuntu 24.04, exfatprogs 1.2.2. Adapt device names as needed.
# License: MIT. Use at your own risk; verify your copy before trusting it.
# ----------------------------------------------------------------------------

set -euo pipefail

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$CYN" "$*" "$RST"; }
ok()   { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%s%s%s\n' "$YEL" "$*" "$RST"; }
die()  { printf '%s%s%s\n' "$RED" "ERROR: $*" "$RST" >&2; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RST"; }

# ---- confirmation helpers --------------------------------------------------
# Require the user to type an exact word (case-sensitive) to proceed.
confirm_word() {
  local prompt="$1" want="$2" ans
  read -r -p "$prompt " ans
  [[ "$ans" == "$want" ]] || die "Confirmation not given (expected '$want'). Aborting."
}

# Present a numbered menu and return the chosen item on stdout.
#   menu_select "Prompt line" "label1|value1" "label2|value2" ...
# The label (left of '|') is shown; the value (right of '|') is returned.
# Always appends a "manual entry" and "quit" option. On manual entry the user
# types a raw value which is returned as-is.
MENU_RESULT=""
menu_select() {
  local prompt="$1"; shift
  local items=("$@") i choice
  echo >&2
  for i in "${!items[@]}"; do
    printf '    %s%2d)%s %s\n' "$BOLD" "$((i+1))" "$RST" "${items[$i]%%|*}" >&2
  done
  printf '    %s%2d)%s %s\n' "$BOLD" "$(( ${#items[@]} + 1 ))" "$RST" "enter a value manually" >&2
  printf '    %s%2d)%s %s\n' "$BOLD" "$(( ${#items[@]} + 2 ))" "$RST" "quit" >&2
  echo >&2
  while true; do
    read -r -p "$prompt " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Enter a number." ; continue; }
    if (( choice >= 1 && choice <= ${#items[@]} )); then
      MENU_RESULT="${items[$((choice-1))]##*|}"; return 0
    elif (( choice == ${#items[@]} + 1 )); then
      read -r -p "Enter value: " MENU_RESULT; return 0
    elif (( choice == ${#items[@]} + 2 )); then
      die "User quit."
    else
      warn "Out of range."
    fi
  done
}

# ---- global state for cleanup ----------------------------------------------
SNAP=""        # dm snapshot name
COW=""         # loop device backing the overlay
MNT=""         # source mountpoint
OVERLAY=""     # overlay file path
KEEP_OVERLAY=0 # set to 1 to keep overlay after run

cleanup() {
  # Always tear down the mapping/loop/mount so nothing dangles, even on error
  # or Ctrl+C. Never touches the physical source.
  set +e
  if [[ -n "$MNT" ]] && mountpoint -q "$MNT"; then sudo umount "$MNT"; fi
  if [[ -n "$SNAP" ]] && sudo dmsetup info "$SNAP" &>/dev/null; then sudo dmsetup remove "$SNAP"; fi
  if [[ -n "$COW" ]] && sudo losetup "$COW" &>/dev/null; then sudo losetup -d "$COW"; fi
  if [[ -n "$OVERLAY" && -f "$OVERLAY" && "$KEEP_OVERLAY" -eq 0 ]]; then sudo rm -f "$OVERLAY"; fi
}
trap cleanup EXIT
trap 'die "Interrupted."' INT TERM

# ---- preflight: required tools ---------------------------------------------
hdr "Preflight: checking required tools"
declare -A PKG=( [fsck.exfat]=exfatprogs [losetup]=util-linux [blockdev]=util-linux
                 [dmsetup]=dmsetup [rsync]=rsync [blkid]=util-linux [findmnt]=util-linux )
missing_pkgs=()
for cmd in "${!PKG[@]}"; do
  command -v "$cmd" &>/dev/null || missing_pkgs+=("${PKG[$cmd]}")
done
if ((${#missing_pkgs[@]})); then
  # de-duplicate
  mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
  warn "Missing tools from packages: ${missing_pkgs[*]}"
  read -r -p "Install them now with apt? [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || die "Cannot proceed without required tools."
  sudo apt update && sudo apt install -y "${missing_pkgs[@]}"
fi
ok "All required tools present."

# ---- select and validate SOURCE -------------------------------------------
hdr "Source disk"
info "Scanning attached disks for exFAT superfloppy candidates..."

# Build a candidate list: whole disks (TYPE=disk) that carry an EXFAT signature
# at byte offset 3 of sector 0 and have NO child partitions. WSL's own virtual
# disks (sda-sdd, ext4/swap) are naturally excluded by the signature test.
src_candidates=()
while read -r name type; do
  [[ "$type" == "disk" ]] || continue
  dev="/dev/$name"
  # skip disks that have partitions (a real superfloppy has none)
  if lsblk -nro NAME "$dev" | tail -n +2 | grep -q .; then continue; fi
  sig=$(sudo dd if="$dev" bs=1 skip=3 count=5 2>/dev/null || true)
  [[ "$sig" == "EXFAT" ]] || continue
  size=$(lsblk -dno SIZE "$dev"); model=$(lsblk -dno MODEL "$dev" 2>/dev/null || true)
  src_candidates+=("$dev  ${size}  ${model:-unknown}|$dev")
done < <(lsblk -dno NAME,TYPE)

if ((${#src_candidates[@]})); then
  ok "Found ${#src_candidates[@]} candidate(s) with an exFAT superfloppy signature."
else
  warn "No exFAT-superfloppy candidates auto-detected. All block devices:"
  lsblk -o NAME,SIZE,FSTYPE,MODEL,TYPE | sed 's/^/    /'
  cat <<EOF

If your source disk isn't listed, it may not be attached yet. Run these in an
*Administrator* PowerShell first, then re-run this script:
    Get-Disk | Format-Table Number,FriendlyName,PartitionStyle,SizeGB
    Set-Disk -Number <N> -IsOffline \$true
    wsl --mount \\\\.\\PHYSICALDRIVE<N> --bare
EOF
fi

menu_select "Select the SOURCE disk (number):" "${src_candidates[@]}"
SRC="$MENU_RESULT"
[[ -b "$SRC" ]] || die "$SRC is not a block device."

# Re-verify the exFAT signature on whatever was ultimately chosen (covers the
# manual-entry path, where the disk was not pre-screened).
SIG=$(sudo dd if="$SRC" bs=1 skip=3 count=5 2>/dev/null || true)
if [[ "$SIG" != "EXFAT" ]]; then
  warn "Sector 0 of $SRC does not carry an 'EXFAT' signature (found: '${SIG:-<none>}')."
  warn "This may not be an exFAT superfloppy. Proceeding could be pointless or unsafe."
  confirm_word "Type PROCEED to continue anyway, anything else to abort:" "PROCEED"
else
  ok "Confirmed exFAT boot signature on $SRC."
fi

SRC_MODEL=$(lsblk -dno MODEL "$SRC" 2>/dev/null || true)
SRC_SIZE=$(lsblk -dno SIZE "$SRC" 2>/dev/null || true)
info "Source: $SRC   size=$SRC_SIZE   model=${SRC_MODEL:-unknown}"
confirm_word "Confirm this is the SOURCE (data-to-recover) disk. Type YES:" "YES"

# ---- select and validate DESTINATION ---------------------------------------
hdr "Destination"
info "Scanning for candidate destination volumes (NTFS / Windows-backed / FUSE)..."

# Candidate destinations: mounted filesystems that are plausibly an NTFS target
# — natively-mounted NTFS (ntfs/ntfs3/fuseblk) or a Windows disk surfaced through
# WSL (drvfs/9p). We show fstype and free space so the choice is informed.
dst_candidates=()
while IFS=$'\t' read -r target fstype avail; do
  case "$fstype" in
    ntfs|ntfs3|fuseblk|drvfs|9p) ;;
    *) continue ;;
  esac
  dst_candidates+=("$target  [${fstype}]  free ${avail}|$target")
done < <(findmnt -rno TARGET,FSTYPE,AVAIL | awk 'BEGIN{OFS="\t"}{print $1,$2,$3}')

if ((${#dst_candidates[@]})); then
  ok "Found ${#dst_candidates[@]} candidate destination(s)."
else
  warn "No obvious NTFS/Windows destinations found. All mounts:"
  findmnt -rno TARGET,FSTYPE,AVAIL | sed 's/^/    /'
fi

menu_select "Select the DESTINATION volume (number):" "${dst_candidates[@]}"
DEST="$MENU_RESULT"
[[ -d "$DEST" ]] || die "$DEST is not a directory."
mountpoint -q "$DEST" || warn "$DEST is not itself a mountpoint; make sure it's on the disk you intend."

# Guard: destination must not live on the source disk.
if [[ "$(findmnt -no SOURCE --target "$DEST" 2>/dev/null)" == "$SRC"* ]]; then
  die "Destination appears to be on the SOURCE disk. Choose a different disk."
fi

# Destination NTFS handling.
#  - A Windows disk surfaced through WSL shows as drvfs/9p from Linux, so we
#    cannot read its true on-disk fstype here -> we REQUIRE the user to confirm.
#  - A natively Linux-mounted NTFS shows as ntfs3/ntfs/fuseblk -> we can verify.
DFS=$(findmnt -no FSTYPE --target "$DEST" 2>/dev/null || echo "unknown")
info "Destination filesystem (as Linux sees it): $DFS"
case "$DFS" in
  ntfs|ntfs3)
    ok "Destination is a Linux-mounted NTFS volume." ;;
  fuseblk)
    warn "Destination is a FUSE block mount (often ntfs-3g). Verify it is NTFS." ;;
  drvfs|9p)
    warn "Destination is a Windows-backed WSL mount; its true format can't be read from Linux." ;;
  ext*|xfs|btrfs|vfat|exfat)
    warn "Destination appears to be '$DFS', which is NOT NTFS. This is probably the wrong disk." ;;
  *)
    warn "Could not determine destination filesystem type." ;;
esac
say "The destination MUST be NTFS-formatted (journaled, handles this data cleanly,"
say "and avoids re-creating the partitionless-exFAT problem you are recovering from)."
confirm_word "Confirm the destination is NTFS. Type NTFS:" "NTFS"

# Backup subfolder: use the exFAT volume label if present, else a timestamp.
LABEL=$(sudo blkid -s LABEL -o value "$SRC" 2>/dev/null || true)
DEFAULT_SUB="recovered_${LABEL:-$(date +%Y%m%d_%H%M%S)}"
read -r -p "Destination subfolder name [${DEFAULT_SUB}]: " SUB
SUB="${SUB:-$DEFAULT_SUB}"
DEST_DIR="${DEST%/}/$SUB"
info "Data will be copied to: $DEST_DIR"

# ---- build the copy-on-write snapshot --------------------------------------
hdr "Building read-only copy-on-write overlay (source stays untouched)"
STAMP=$(date +%Y%m%d_%H%M%S)
OVERLAY="${DEST%/}/.cow_${STAMP}.img"
SNAP="recover_${STAMP}"
MNT="/mnt/recover_${STAMP}"

# Overlay only needs to hold changed sectors (boot region + a little slack).
# 2 GiB sparse is comfortably more than enough and costs almost no real space.
info "Creating 2 GiB sparse overlay: $OVERLAY"
sudo truncate -s 2G "$OVERLAY"

COW=$(sudo losetup -f --show "$OVERLAY")
info "Overlay attached as loop device: $COW"

SZ=$(sudo blockdev --getsz "$SRC")
info "Source size: $SZ sectors"

# snapshot: <origin=SRC read-through> <cow=loop> P(ersistent) 8(=4KiB chunks)
echo "0 $SZ snapshot $SRC $COW P 8" | sudo dmsetup create "$SNAP"
SNAPDEV="/dev/mapper/$SNAP"
[[ -e "$SNAPDEV" ]] || die "Failed to create snapshot device $SNAPDEV"
ok "Snapshot device ready: $SNAPDEV"

# Sanity: the snapshot must read through to the same EXFAT boot sector.
SNAP_SIG=$(sudo dd if="$SNAPDEV" bs=1 skip=3 count=5 2>/dev/null || true)
[[ "$SNAP_SIG" == "EXFAT" ]] || die "Snapshot does not read through to the exFAT source correctly."
ok "Snapshot reads through to the source correctly."

# ---- repair the boot region ON THE SNAPSHOT --------------------------------
hdr "Repairing boot region on the snapshot (writes go to the overlay, not the disk)"
LOG=$(mktemp)
set +e
sudo fsck.exfat -y "$SNAPDEV" 2>&1 | tee "$LOG"
FSCK_RC=${PIPESTATUS[0]}
set -e
echo

# fsck exit codes: 0 = no errors, 1 = errors corrected. >=4 typically means
# errors could NOT be corrected -> deeper corruption than a boot checksum.
if (( FSCK_RC >= 4 )); then
  warn "fsck exited $FSCK_RC: the filesystem could not be fully repaired."
  warn "This is NOT the simple boot-checksum case; there may be real structural"
  warn "damage. STOPPING so a human can inspect. The source has not been touched."
  rm -f "$LOG"
  die "Halting on uncorrectable filesystem errors."
fi

if grep -qi "clean" "$LOG"; then
  ok "fsck reports the volume is clean. This is the expected boot-checksum-only case."
else
  warn "fsck did not report a clean volume (exit $FSCK_RC). Review the output above."
  warn "If you don't understand what it fixed, stop and get a second opinion."
  confirm_word "Type CONTINUE to mount and copy anyway, anything else to abort:" "CONTINUE"
fi
rm -f "$LOG"

# ---- mount the repaired snapshot read-only ---------------------------------
hdr "Mounting repaired snapshot READ-ONLY"
sudo mkdir -p "$MNT"
sudo mount -t exfat -o ro "$SNAPDEV" "$MNT"
if ! mount | grep " $MNT " | grep -qw ro; then
  die "Mount is NOT read-only. Refusing to proceed."
fi
ok "Mounted read-only at $MNT"
echo
info "Top-level contents:"
sudo ls -la "$MNT" | sed 's/^/    /'
echo
info "Volume usage:"
df -h "$MNT" | sed 's/^/    /'

# ---- capacity check --------------------------------------------------------
hdr "Capacity check"
USED=$(df -B1 --output=used "$MNT"  | tail -1 | tr -d ' ')
AVAIL=$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')
info "Source data: $(numfmt --to=iec "$USED")   Destination free: $(numfmt --to=iec "$AVAIL")"
if (( AVAIL < USED )); then
  die "Not enough free space on destination ($(numfmt --to=iec "$AVAIL") < $(numfmt --to=iec "$USED"))."
fi
ok "Destination has enough space."
confirm_word "Ready to copy. Type COPY to begin:" "COPY"

# ---- copy ------------------------------------------------------------------
hdr "Copying data (this can take hours for a full disk)"
mkdir -p "$DEST_DIR"
# exFAT has no Unix ownership/perms and the destination is Windows-backed, so we
# preserve times only and suppress perm/owner/group noise. rsync is resumable:
# re-running the same command picks up where an interrupted copy left off.
rsync -rt --info=progress2 --no-perms --no-owner --no-group "$MNT"/ "$DEST_DIR"/
ok "Copy finished."

# ---- verify ----------------------------------------------------------------
hdr "Verifying copy"
say "Fast check (presence + size + mtime for every file). Prints nothing if all match."
if rsync -rn --itemize-changes --no-perms --no-owner --no-group "$MNT"/ "$DEST_DIR"/ | grep -q .; then
  warn "The fast check found differences (listed above). Investigate before trusting the copy."
else
  ok "Fast check clean: every file present with matching size and timestamp."
fi
echo
read -r -p "Also run a full byte-for-byte checksum verify? (slow, re-reads everything) [y/N] " v
if [[ "$v" == "y" || "$v" == "Y" ]]; then
  say "Running full checksum verify (this re-reads all data on both sides)..."
  if rsync -rnc --itemize-changes --no-perms --no-owner --no-group "$MNT"/ "$DEST_DIR"/ | grep -q .; then
    warn "Checksum verify found mismatches (listed above)."
  else
    ok "Checksum verify clean: every file is byte-identical."
  fi
fi

# ---- done: teardown handled by trap, print Windows steps -------------------
hdr "Done"
ok "Data recovered to: $DEST_DIR"
say "The Linux-side overlay/snapshot/mount will be torn down automatically on exit."
read -r -p "Keep the COW overlay file for inspection? (normally no) [y/N] " k
[[ "$k" == "y" || "$k" == "Y" ]] && KEEP_OVERLAY=1
echo
warn "FINISH IN WINDOWS — run these in an *Administrator* PowerShell:"
# Best-effort: recover the PHYSICALDRIVE number if the user exported it; else placeholder.
cat <<EOF
    wsl --unmount \\\\.\\PHYSICALDRIVE<N>
    Set-Disk -Number <N> -IsOffline \$false
EOF
say "(<N> is the disk number you set offline in the prerequisites.)"
echo
ok "The physical source disk was never written to. You now have two copies:"
say "  - the recovered data at $DEST_DIR"
say "  - the original source disk, unchanged"
