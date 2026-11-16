#!/usr/bin/env bash
# Read-only inventory of the Azure side. Nothing here mutates a resource.
# Requires: az (logged in), jq. Optional: VM running for the runtime probe.
#
#   RG=SIMULANIS-IN VM=Opencti ./scripts/azure-inventory.sh
#
set -euo pipefail

RG="${RG:-SIMULANIS-IN}"
VM="${VM:-Opencti}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/opencti}"
OUT="${OUT:-out/azure}"

command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
mkdir -p "$OUT"
say() { printf '\n=== %s ===\n' "$*"; }

say "context"
az account show -o json                                    > "$OUT/account.json"
az account list --all -o json                              > "$OUT/subscriptions.json"

say "resource group"
az group show -n "$RG" -o json                             > "$OUT/rg.json" || true

say "virtual machines"
az vm list -d -g "$RG" -o json                             > "$OUT/vms.json"
az vm show -g "$RG" -n "$VM" -d -o json                    > "$OUT/vm.json"

say "disks and snapshots"
az disk list -g "$RG" -o json                              > "$OUT/disks.json"
az snapshot list -g "$RG" -o json                          > "$OUT/snapshots.json"

say "network reality you are leaving behind"
az network nic list -g "$RG" -o json                       > "$OUT/nics.json"
az network nsg list -g "$RG" -o json                       > "$OUT/nsgs.json"
az network public-ip list -g "$RG" -o json                 > "$OUT/public-ips.json"
az network vnet list -g "$RG" -o json                      > "$OUT/vnets.json"
az network private-dns zone list -g "$RG" -o json          > "$OUT/private-dns.json" 2>/dev/null || true

say "identity / extensions / boot diagnostics"
az vm identity show -g "$RG" -n "$VM" -o json              > "$OUT/identity.json"    2>/dev/null || true
az vm extension list -g "$RG" --vm-name "$VM" -o json      > "$OUT/extensions.json"  2>/dev/null || true
az vm boot-diagnostics get-boot-log -g "$RG" -n "$VM"      > "$OUT/boot-log.txt"     2>/dev/null || true

say "runtime probe (needs the VM running)"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts "
echo '## os';      head -3 /etc/os-release; uname -r
echo '## docker';  docker version --format '{{.Server.Version}}' 2>/dev/null
echo '## compose'; docker compose version 2>/dev/null
echo '## images';  docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}'
echo '## ps';      ( cd $COMPOSE_DIR && docker compose ps --format '{{.Name}} {{.Image}} {{.Status}}' ) 2>/dev/null || docker ps --format '{{.Names}} {{.Image}} {{.Status}}'
echo '## volumes'; docker volume ls
echo '## df';      df -h
echo '## mem';     free -m
echo '## sysctl';  sysctl vm.max_map_count
echo '## env-keys'; ( cd $COMPOSE_DIR && grep -o '^[A-Z_]*' .env | sort ) 2>/dev/null
echo '## pkg-count'; dpkg -l | wc -l
" -o json                                                  > "$OUT/runtime.json"

say "activity log (who did what, last 30 days)"
az monitor activity-log list -g "$RG" --max-events 500 \
  --start-time "$(date -u -d '30 days ago' +%FT%TZ)" -o json > "$OUT/activity-log.json" 2>/dev/null || true

say "summary"
jq -r '.[] | [.name, .powerState, (.hardwareProfile.vmSize // "-"), (.publicIps // "-")] | @tsv' "$OUT/vms.json" 2>/dev/null || true
echo
echo "Wrote $OUT/ — commit the JSON (no secrets in it) as the pre-migration baseline."
echo "IMPORTANT: .env is NOT collected here. Retrieve it (and anything in Key Vault) separately."
