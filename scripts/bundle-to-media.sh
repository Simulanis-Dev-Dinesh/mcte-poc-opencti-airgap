#!/usr/bin/env bash
# Copy the migration bundle onto a storage device and verify it THERE.
#
#   ./scripts/bundle-to-media.sh --src ~/opencti-bundle --dest /mnt/bundle/opencti-bundle
#   ./scripts/bundle-to-media.sh --src ~/opencti-bundle --dest /mnt/bundle/opencti-bundle --apply
#
# Dry run by default. Checks the filesystem (FAT32 cannot hold a 6.8 GB file),
# checks free space, copies with rsync --checksum, re-runs the checksums on the
# device itself, syncs, and writes a transfer record.
#
# It does NOT encrypt the device and does NOT delete anything from the source.
# See docs/DEPLOY-ANY-VM.md for the LUKS step and the chain-of-custody record.
set -euo pipefail

SRC=""
DEST=""
APPLY=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --src)   SRC="${2:-}"; shift 2 ;;
    --dest)  DEST="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$SRC" ] && [ -n "$DEST" ] || { echo "--src and --dest are required" >&2; usage 1; }
[ -d "$SRC" ] || { echo "ERROR: source not found: $SRC" >&2; exit 1; }
[ -d "$DEST" ] || { echo "ERROR: destination not mounted: $DEST" >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
plan() { if [ "$APPLY" -eq 1 ]; then say "  RUN   $*"; else say "  WOULD $*"; fi; }

fstype="$(findmnt -no FSTYPE --target "$DEST" 2>/dev/null || echo unknown)"
say "source:      $SRC"
say "destination: $DEST"
say "filesystem:  $fstype"

[ "$APPLY" -eq 1 ] || say "DRY RUN — nothing will be copied. Add --apply."

# ---------------------------------------------------------------- FAT32 guard
if [ "$fstype" = "vfat" ]; then
  over="$(find "$SRC" -maxdepth 1 -type f -size +3G -printf '%f\t%s\n' 2>/dev/null || true)"
  if [ -n "$over" ]; then
    say
    echo "ERROR: the destination is FAT32, which cannot store a file over 4 GiB." >&2
    echo "       These files will fail part-way through the copy:" >&2
    printf '         %s\n' "$over" >&2
    echo "       Reformat the device as exFAT, NTFS or ext4." >&2
    exit 1
  fi
  say "WARNING: FAT32 — no permissions are preserved and files must stay under 4 GiB."
fi

# ---------------------------------------------------------------- space
need="$(du -sb "$SRC" | cut -f1)"
avail="$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')"
say "need:        $(numfmt --to=iec "$need")"
say "available:   $(numfmt --to=iec "$avail")"
if [ "$avail" -lt "$need" ]; then
  echo "ERROR: not enough free space on the destination." >&2
  exit 1
fi

# ---------------------------------------------------------------- copy
plan "copy $SRC/ -> $DEST/  (rsync --checksum if available, else cp)"
if [ "$APPLY" -eq 1 ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -ah --info=progress2 --checksum "$SRC"/ "$DEST"/
  else
    say "  rsync not installed — using cp; the checksum pass below is what proves it"
    cp -a "$SRC"/. "$DEST"/
  fi
  say "  copied"
fi

# ---------------------------------------------------------------- verify there
plan "verify checksums on the device, not on the source"
if [ "$APPLY" -eq 1 ]; then
  if [ -f "$DEST/sha256sums.txt" ]; then
    ( cd "$DEST" && sha256sum -c --ignore-missing sha256sums.txt ) || {
      echo "ERROR: checksum mismatch on the device. Do not carry it." >&2
      exit 1
    }
    # anything on the device that the checksum file does not cover
    uncovered="$(cd "$DEST" && for f in *; do
        [ "$f" = "sha256sums.txt" ] && continue
        grep -q "  $f\$" sha256sums.txt || echo "$f"
      done)"
    [ -n "$uncovered" ] && say "  note: not covered by sha256sums.txt: $(echo $uncovered)"
  else
    echo "ERROR: no sha256sums.txt in $DEST — cannot verify." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- transfer record
plan "write TRANSFER-RECORD.txt"
if [ "$APPLY" -eq 1 ]; then
  {
    echo "OpenCTI air-gap bundle — transfer record"
    echo "generated : $(date -Is) on $(hostname)"
    echo "source    : $SRC"
    echo "device    : $DEST ($fstype)"
    echo "files     : $(find "$DEST" -maxdepth 1 -type f | wc -l)"
    echo "bytes     : $need"
    echo "checksums : $(sha256sum "$DEST/sha256sums.txt" 2>/dev/null | cut -d' ' -f1)"
    echo
    echo "Fill in by hand:"
    echo "  media serial : "
    echo "  carrier      : "
    echo "  signed out   :            by: "
    echo "  signed in    :            by: "
    echo "  gpg passphrase held by (not on this device): "
  } > "$DEST/TRANSFER-RECORD.txt"
  say "  wrote $DEST/TRANSFER-RECORD.txt"
fi

# ---------------------------------------------------------------- flush
plan "sync, then unmount by hand"
if [ "$APPLY" -eq 1 ]; then
  sync
  say "  flushed to the device"
fi

say
if [ "$APPLY" -eq 1 ]; then
  say "Done. Now:"
  say "  sudo umount \"$(findmnt -no TARGET --target "$DEST" 2>/dev/null || echo "$DEST")\""
  say "  (and 'sudo cryptsetup close <name>' if the device is LUKS-encrypted)"
  say "Never pull a mounted drive."
else
  say "Nothing copied. Re-run with --apply."
fi
