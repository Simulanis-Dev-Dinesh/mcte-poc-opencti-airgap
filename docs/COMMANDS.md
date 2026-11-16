# Command reference

## A. Check everything on the Azure side

```bash
az login
az account set --subscription "<sub-id>"

# who/what/where
az account show -o table
az group list -o table
az vm list -d -g SIMULANIS-IN -o table
az vm show -g SIMULANIS-IN -n Opencti -d -o json

# disks, snapshots, sizes
az disk list -g SIMULANIS-IN -o table
az snapshot list -g SIMULANIS-IN -o table
az disk show -g SIMULANIS-IN -n <disk> --query '{sku:sku.name,gb:diskSizeGb,state:diskState}'

# network you are leaving behind
az network nic show -g SIMULANIS-IN -n <nic> -o json
az network nsg rule list -g SIMULANIS-IN --nsg-name <nsg> -o table
az network public-ip list -g SIMULANIS-IN -o table

# runtime facts without SSH (audited in the activity log)
az vm run-command invoke -g SIMULANIS-IN -n Opencti --command-id RunShellScript \
  --scripts "docker compose version; docker images --digests; df -h; sysctl vm.max_map_count"

# cost/ownership trail
az monitor activity-log list -g SIMULANIS-IN --max-events 100 -o table
```

Or just: `make azure-inventory` (writes everything to `out/azure/`).

## B. Check everything inside OpenCTI

On the host:

```bash
cd /opt/opencti
docker compose ps                                  # all Up, no restarts
docker compose config --images                     # authoritative image list
docker images --digests                            # tag -> digest
docker volume ls && docker system df -v            # sizes

# elasticsearch / opensearch
curl -s localhost:9200/_cluster/health?pretty
curl -s localhost:9200/_cat/indices?v&s=index
curl -s localhost:9200/_cat/allocation?v

# rabbitmq + redis
docker exec $(docker ps -qf name=rabbitmq) rabbitmqctl list_queues name messages consumers
docker exec $(docker ps -qf name=redis) redis-cli info memory
```

Or `./scripts/stack-healthcheck.sh` (covers all of the above plus time sync and TLS).

Content and configuration:

```bash
export OPENCTI_URL=https://<host>
export OPENCTI_TOKEN=<token>
./scripts/opencti-inventory.py --out out/inventory-before.json
```

Ad-hoc GraphQL:

```bash
curl -s -X POST "$OPENCTI_URL/graphql" \
  -H "Authorization: Bearer $OPENCTI_TOKEN" -H 'Content-Type: application/json' \
  -d '{"query":"query { stixCoreObjectsNumber(types: [\"Indicator\"]) { total } }"}'
```

Connector/version health in the UI: **Data > Connectors** (status, last run,
queues), **Settings > About** (platform version).

## C. Wazuh side

```bash
# manager
systemctl status wazuh-manager
/var/ossec/bin/wazuh-control info
tail -f /var/ossec/logs/integrations.log        # integratord output

# indexer / dashboard
curl -sk -u admin:<pw> https://<indexer>:9200/_cluster/health?pretty
curl -sk -u admin:<pw> https://<indexer>:9200/_cat/indices/wazuh-alerts-*?v
```

See `docs/WAZUH-INTEGRATION.md`.

## D. GitHub / bundle

```bash
gh repo view
gh workflow run mirror-images.yml
gh run list --workflow=mirror-images.yml
gh release list
gh release download bundle-YYYYMMDDHHMM --pattern '*.tar*'   # on the transfer host
sha256sum -c sha256sums.txt
```

Inside the gap: `./scripts/load-into-registry.sh`, then `docker compose up -d`.
