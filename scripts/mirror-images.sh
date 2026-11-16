#!/usr/bin/env bash
# Mirror every image in images.txt to GHCR with digests preserved, and build
# oci archives for physical transfer. Run on an internet-connected host.
#
#   DEST_PREFIX=ghcr.io/<owner>/opencti-airgap ./scripts/mirror-images.sh
#
# GHCR paths must be lowercase. --preserve-digests fails closed rather than
# silently pushing a different image.
#
# Destination naming keeps the registry-relative path and flattens separators.
# Stripping it collides: xtmone/platform and opencti/platform both reduce to
# "platform", which silently drops one image from the bundle. Collisions and
# digest mismatches are now hard errors.
set -euo pipefail

IMAGES_FILE="${IMAGES_FILE:-images.txt}"
DEST_PREFIX="${DEST_PREFIX:?set DEST_PREFIX, e.g. ghcr.io/yourorg/opencti-airgap}"
DEST_PREFIX="$(printf '%s' "$DEST_PREFIX" | tr '[:upper:]' '[:lower:]')"
DEST_PREFIX="${DEST_PREFIX%/}"
BUNDLE_DIR="${BUNDLE_DIR:-out/bundle}"
mkdir -p "$BUNDLE_DIR"

command -v skopeo >/dev/null || { echo "skopeo not installed" >&2; exit 1; }

# source ref -> unique, lowercase, registry-safe destination name
dest_name() {
  local ref="${1%%@*}"                   # drop digest
  local last="${ref##*/}"
  if [ "${last%:*}" != "$last" ]; then   # tag, only if it is on the last segment
    ref="${ref%:*}"
  fi
  case "$ref" in
    */*/*) ref="${ref#*/}" ;;            # drop the registry host: host/org/img
  esac
  printf '%s' "$ref" | tr '/: ' '---' | tr '[:upper:]' '[:lower:]'
}

manifest="$BUNDLE_DIR/manifest.tsv"
: > "$manifest"
printf 'source\tdestination\tdigest\n' >> "$manifest"

declare -A seen=()
count=0
while read -r src; do
  [ -z "${src// }" ] && continue
  case "$src" in \#*) continue ;; esac

  name="$(dest_name "$src")"
  dest="$DEST_PREFIX/$name"

  if [ -n "${seen[$name]:-}" ]; then
    echo "ERROR: destination name collision on '$name':" >&2
    echo "  ${seen[$name]}" >&2
    echo "  $src" >&2
    echo "Two different images would overwrite each other. Fix dest_name()." >&2
    exit 1
  fi
  seen[$name]="$src"

  echo "==> $src"
  echo "    -> $dest"
  skopeo copy --all --preserve-digests --retry-times 3 "docker://$src" "docker://$dest"

  digest=$(skopeo inspect --format '{{.Digest}}' "docker://$dest")

  # The digest pinned in images.txt is the contract. Verify it, do not assume.
  pinned="${src##*@}"
  if [ "$pinned" != "$src" ] && [ "${digest#sha256:}" != "${pinned#sha256:}" ]; then
    echo "ERROR: digest mismatch for $src" >&2
    echo "  pinned in images.txt: $pinned" >&2
    echo "  actually pushed:      $digest" >&2
    exit 1
  fi

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
