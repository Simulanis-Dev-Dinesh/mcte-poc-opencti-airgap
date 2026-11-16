#!/usr/bin/env bash
# Inside the air gap: push oci archives into the internal registry.
#
#   LOCAL_REGISTRY=registry.internal:5000 BUNDLE_DIR=./bundle ./scripts/load-into-registry.sh
#
set -euo pipefail
BUNDLE_DIR="${BUNDLE_DIR:-./bundle}"
LOCAL_REGISTRY="${LOCAL_REGISTRY:?set LOCAL_REGISTRY, e.g. registry.internal:5000}"
TLS_VERIFY="${TLS_VERIFY:-true}"

cd "$BUNDLE_DIR"
sha256sum -c sha256sums.txt

# manifest.tsv: source <TAB> destination <TAB> digest
tail -n +2 manifest.tsv | while IFS=$'\t' read -r src dest digest; do
  name="${dest##*/}"
  archive="$name.oci.tar"
  [ -f "$archive" ] || { echo "missing $archive" >&2; exit 1; }
  target="docker://$LOCAL_REGISTRY/$name"
  echo "==> $archive -> $target"
  if [ "$TLS_VERIFY" = "true" ]; then
    skopeo copy --all "oci-archive:$archive" "$target"
  else
    skopeo copy --all --dest-tls-verify=false "oci-archive:$archive" "$target"
  fi
  skopeo inspect --tls-verify="$TLS_VERIFY" "$target" >/dev/null && echo "    verified"
done

echo
echo "All images present in $LOCAL_REGISTRY."
echo "Point the compose file at it, e.g.:"
echo "  sed -i 's#image: opencti/platform#image: $LOCAL_REGISTRY/platform#' docker-compose.yml"
