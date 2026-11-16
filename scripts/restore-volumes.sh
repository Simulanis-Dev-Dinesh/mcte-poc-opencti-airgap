#!/usr/bin/env bash
# Restore volume tarballs on the TARGET host (inside the air gap).
# Elasticsearch refuses to start if its data dir is not owned by uid 1000.
#
#   SRC=./volumes ./scripts/restore-volumes.sh
#
set -euo pipefail
SRC="${SRC:-./volumes}"
PROJECT="${PROJECT:-opencti}"

cd "$SRC"
sha256sum -c sha256sums.txt

for f in *.tgz; do
  base="${f%.tgz}"                       # e.g. opencti_esdata
  vol="$base"
  case "$base" in
    *esdata)    vol="${PROJECT}_esdata" ;;
    *s3data)    vol="${PROJECT}_s3data" ;;
    *redisdata) vol="${PROJECT}_redisdata" ;;
    *amqpdata)  vol="${PROJECT}_amqpdata" ;;
  esac
  echo "==> $f -> volume $vol"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol":/data -v "$PWD":/backup alpine \
    sh -c "cd /data && tar xzf /backup/$f"
done

echo "==> fixing ownership (esdata must be uid 1000:0)"
sudo chown -R 1000:0 "/var/lib/docker/volumes/${PROJECT}_esdata/_data" 2>/dev/null || true

echo
echo "Now start the SAME OpenCTI version you left Azure on: docker compose up -d"
