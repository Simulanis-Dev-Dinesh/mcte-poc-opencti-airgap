#!/usr/bin/env bash
# Mirror every image in images.txt to GHCR with digests preserved, and build
# oci archives for physical transfer. Run on an internet-connected host.
#
#   DEST_PREFIX=ghcr.io/<owner>/opencti-airgap ./scripts/mirror-images.sh
#
# GHCR paths must be lowercase. --preserve-digests fails closed rather than
# silently pushing a different image.
set -euo pipefail

IMAGES_FILE="${IMAGES_FILE:-images.txt}"
DEST_PREFIX="${DEST_PREFIX:?set DEST_PREFIX, e.g. ghcr.io/yourorg/opencti-airgap}"
DEST_PREFIX="$(printf '%s' "$DEST_PREFIX" | tr '[:upper:]' '[:lower:]')"
BUNDLE_DIR="${BUNDLE_DIR:-out/bundle}"
mkdir -p "$BUNDLE_DIR"

command -v skopeo >/dev/null || { echo "skopeo not installed" >&2; exit 1; }

manifest="$BUNDLE_DIR/manifest.tsv"
: > "$manifest"
printf 'source\tdestination\tdigest\n' >> "$manifest"

count=0
while read -r src; do
  [ -z "${src// }" ] && continue
  case "$src" in \#*) continue ;; esac

  name="${src##*/}"          # strip registry/org
  name="${name%%@*}"         # strip digest
  name="${name%%:*}"         # strip tag
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  dest="$DEST_PREFIX/$name"

  echo "==> $src"
  echo "    -> $dest"
  skopeo copy --all --preserve-digests --retry-times 3 "docker://$src" "docker://$dest"

  digest=$(skopeo inspect --format '{{.Digest}}' "docker://$dest")
  printf '%s\t%s\t%s\n' "$src" "$dest" "$digest" >> "$manifest"

  echo "    -> oci-archive:$BUNDLE_DIR/$name.oci.tar"
  skopeo copy --all "docker://$src" "oci-archive:$BUNDLE_DIR/$name.oci.tar:$src"
  count=$((count + 1))
done < "$IMAGES_FILE"

[ "$count" -gt 0 ] || { echo "images.txt has no active entries" >&2; exit 1; }

( cd "$BUNDLE_DIR" && sha256sum ./*.oci.tar > sha256sums.txt )

echo
echo "Mirrored $count image(s)."
echo "Bundle: $BUNDLE_DIR/  (manifest.tsv, sha256sums.txt, *.oci.tar)"
du -sh "$BUNDLE_DIR"
