#!/usr/bin/env bash
# Restore volume tarballs on the TARGET host (inside the air gap).
#
#   SRC=./volumes PROJECT=xtm ./scripts/restore-volumes.sh
#
# Elasticsearch refuses to start if its data dir is not owned by uid 1000.
#
# Volume names come from the tarball filenames. The compose project on this
# platform is "xtm", so the tarballs are already xtm_esdata.tgz, xtm_s3data.tgz
# and so on. Do NOT rewrite them onto a different project prefix: the data then
# lands in a volume the stack never mounts, `docker compose up` creates a fresh
# empty one, and the platform comes up looking healthy and completely empty.
set -euo pipefail
SRC="${SRC:-./volumes}"
PROJECT="${PROJECT:-xtm}"

cd "$SRC"

if [ -f sha256sums.txt ]; then
  sha256sum -c --ignore-missing sha256sums.txt
else
  echo "WARN: no sha256sums.txt in $SRC — skipping integrity check" >&2
fi

shopt -s nullglob
tgz=( *.tgz )
[ "${#tgz[@]}" -gt 0 ] || { echo "ERROR: no .tgz files in $SRC" >&2; exit 1; }

for f in "${tgz[@]}"; do
  vol="${f%.tgz}"
  case "$vol" in
    "${PROJECT}_"*) ;;                  # already project-prefixed, keep as is
    *) vol="${PROJECT}_${vol}" ;;       # bare name, add the prefix
  esac
  echo "==> $f -> volume $vol"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol":/data -v "$PWD":/backup alpine \
    sh -c "cd /data && tar xzf /backup/$f"
done

# esdata must be owned by 1000:0 or Elasticsearch will not start. Resolve the
# real data-root instead of assuming /var/lib/docker, and fail loudly.
DATA_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker}"
ES_DATA="$DATA_ROOT/volumes/${PROJECT}_esdata/_data"
echo "==> esdata ownership: $ES_DATA must be 1000:0"
if [ -d "$ES_DATA" ]; then
  sudo chown -R 1000:0 "$ES_DATA"
else
  echo "ERROR: $ES_DATA does not exist." >&2
  echo "       Check PROJECT (currently '$PROJECT') and the tarball names." >&2
  exit 1
fi

echo
echo "Restored ${#tgz[@]} volume(s)."
echo "Now start the SAME version you left Azure on, with BOTH compose files:"
echo "  docker compose -f docker-compose.yml -f docker-compose.https.yml up -d"
