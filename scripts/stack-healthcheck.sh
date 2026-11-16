#!/usr/bin/env bash
# Full state check of an OpenCTI host. Runs identically on Azure and in the air gap,
# so the two outputs can be diffed.
#
#   COMPOSE_DIR=/opt/opencti ./scripts/stack-healthcheck.sh
#
set -uo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/opencti}"
OUT="${OUT:-out/health-$(hostname)-$(date +%Y%m%dT%H%M%S)}"
ES_URL="${ES_URL:-http://localhost:9200}"
mkdir -p "$OUT"
step() { printf '\n=== %s ===\n' "$*"; }

step "containers"
docker version                                    > "$OUT/docker-version.txt" 2>&1
docker compose version                            >> "$OUT/docker-version.txt" 2>&1
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$OUT/ps.txt" 2>&1
docker images --digests                           > "$OUT/images.txt" 2>&1
docker volume ls                                  > "$OUT/volumes.txt" 2>&1
( cd "$COMPOSE_DIR" && docker compose config --images ) > "$OUT/compose-images.txt" 2>&1

step "volume sizes"
for v in $(docker volume ls -q); do
  size=$(docker run --rm -v "$v":/x alpine du -sh /x 2>/dev/null | awk '{print $1}')
  printf '%s\t%s\n' "$v" "${size:-?}"
done > "$OUT/volume-sizes.txt" 2>&1

step "elasticsearch / opensearch"
curl -sf "$ES_URL/_cluster/health?pretty"         > "$OUT/es-health.json" 2>&1
curl -sf "$ES_URL/_cat/indices?v&s=index"         > "$OUT/es-indices.txt" 2>&1
curl -sf "$ES_URL/_cat/nodes?v"                   > "$OUT/es-nodes.txt" 2>&1
curl -sf "$ES_URL/_cat/allocation?v"              > "$OUT/es-allocation.txt" 2>&1
curl -sf "$ES_URL/_nodes/stats/fs?pretty" | jq '.nodes[].fs.total' > "$OUT/es-fs.json" 2>&1

step "rabbitmq"
rmq=$(docker ps -qf name=rabbitmq | head -1)
[ -n "$rmq" ] && docker exec "$rmq" rabbitmqctl list_queues name messages consumers > "$OUT/rmq-queues.txt" 2>&1

step "redis"
rd=$(docker ps -qf name=redis | head -1)
[ -n "$rd" ] && docker exec "$rd" redis-cli info memory > "$OUT/redis-memory.txt" 2>&1

step "object storage"
# XTM One runs pgsty/silo where older stacks ran MinIO. Check both so this
# step is never silently empty (an empty file always "matches").
os_ctr=""
for cand in silo minio; do
  c=$(docker ps -qf "name=$cand" | head -1)
  [ -n "$c" ] && { os_ctr="$c"; break; }
done
if [ -n "$os_ctr" ]; then
  { echo "container=$os_ctr"; docker exec "$os_ctr" du -sh /data 2>/dev/null; } \
    > "$OUT/object-storage.txt" 2>&1
else
  echo "no silo/minio container found" > "$OUT/object-storage.txt"
fi

step "host"
df -h                                             > "$OUT/df.txt" 2>&1
free -m                                           > "$OUT/free.txt" 2>&1
sysctl vm.max_map_count                           > "$OUT/sysctl.txt" 2>&1
nproc                                             > "$OUT/cpu.txt" 2>&1

step "time sync (drift breaks tokens and certs)"
timedatectl                                       > "$OUT/time.txt" 2>&1
chronyc tracking                                  > "$OUT/chrony.txt" 2>&1 || true

step "tls"
base=$(grep -hoP '^(APP__BASE_URL|OPENCTI_BASE_URL|OPENCTI_HOST)=\K.*' "$COMPOSE_DIR/.env" 2>/dev/null | tr -d '"' | head -1)
if [ -n "$base" ]; then
  hostport=$(printf '%s' "$base" | sed -E 's#https?://##; s#/.*##')
  case "$hostport" in *:*) ;; *) hostport="$hostport:443";; esac
  echo | openssl s_client -connect "$hostport" -servername "${hostport%%:*}" 2>/dev/null \
    | openssl x509 -noout -subject -dates > "$OUT/tls.txt" 2>&1
  printf 'base_url=%s\n' "$base" >> "$OUT/tls.txt"
fi

step "listening ports"
ss -lntp                                          > "$OUT/ports.txt" 2>&1 || true

echo
echo "Wrote $OUT/"
echo "Key lines to compare before/after:"
echo "  es-health.json -> status / number_of_nodes / unassigned_shards"
echo "  ps.txt         -> every service Up, no restart loops"
echo "  es-indices.txt -> doc counts per index"
echo "  volume-sizes.txt, object-storage.txt"
