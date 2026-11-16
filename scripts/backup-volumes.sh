#!/usr/bin/env bash
# Consistent volume backup on the SOURCE host. Stops the stack first.
#
#   COMPOSE_DIR=/opt/opencti ./scripts/backup-volumes.sh
#
set -euo pipefail
COMPOSE_DIR="${COMPOSE_DIR:-/opt/opencti}"
OUT="${OUT:-out/volumes}"
mkdir -p "$OUT"

cd "$COMPOSE_DIR"
echo "==> stopping stack for an app-consistent copy"
docker compose stop

# volume names are prefixed with the compose project name; discover, don't guess
mapfile -t vols < <(docker volume ls -q | grep -Ei 'esdata|s3data|redisdata|amqpdata' || true)
[ "${#vols[@]}" -gt 0 ] || { echo "no matching volumes found" >&2; exit 1; }

for v in "${vols[@]}"; do
  echo "==> $v"
  docker run --rm -v "$v":/data -v "$PWD/$OUT":/backup alpine \
    tar czf "/backup/$v.tgz" -C /data .
done

( cd "$OUT" && sha256sum ./*.tgz > sha256sums.txt )
echo
echo "Wrote $OUT/"
echo "Now: az snapshot create ... (belt and braces), then az vm deallocate."
