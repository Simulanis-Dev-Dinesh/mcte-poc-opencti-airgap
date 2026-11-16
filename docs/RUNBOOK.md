# Migration runbook — Azure to air gap

Two hard rules: migrate the *stack*, not the VM; and do not change versions
during the move.

## Phase 0 — Baseline (1 day)

- [ ] `make azure-inventory` — commit `out/azure/`
- [ ] `make opencti-inventory` — commit `out/inventory-before.json`
- [ ] Capture `.env` and any Key Vault secrets into your secret store (not git)
- [ ] Confirm the Enterprise licence survives the move (platform ID bound)
- [ ] Record `APP__ENCRYPTION_KEY` — without it encrypted secrets are lost
- [ ] Start a STIX export as a fallback (`pycti` `export_list`, simple and full)

## Phase 1 — Freeze and snapshot

```bash
# on the VM: app-consistent stop
cd /opt/opencti && docker compose stop

# on your workstation
./scripts/backup-volumes.sh                     # tar the four volumes
az snapshot create -g SIMULANIS-IN -n opencti-os-$(date +%F)   --source <os-disk-id>
az snapshot create -g SIMULANIS-IN -n opencti-data-$(date +%F) --source <data-disk-id>
az vm deallocate -g SIMULANIS-IN -n Opencti     # rollback point, disks retained
```

For large ES data, `az snapshot grant-access` + `azcopy copy` beats tar over SSH
and is resumable.

## Phase 2 — Bundle

```bash
# images.txt from: docker compose config --images (pin by digest)
DEST_PREFIX=ghcr.io/<owner>/opencti-airgap ./scripts/mirror-images.sh
gh release create bundle-$(date +%Y%m%d) out/bundle/*.oci.tar \
  out/bundle/sha256sums.txt out/bundle/manifest.tsv
git bundle create repo.bundle --all
```

Encrypt (age/gpg), carry `sha256sums.txt`, two-person sign-off, transfer log.

## Phase 3 — Stand up the target

```bash
# host prep
echo 'vm.max_map_count=1048575' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
# internal NTP, internal CA certs, docker data-root on the SSD volume, log rotation

LOCAL_REGISTRY=registry.internal:5000 ./scripts/load-into-registry.sh
SRC=./volumes PROJECT=opencti ./scripts/restore-volumes.sh
docker compose -f docker-compose.yml -f compose/docker-compose.override.yml up -d
```

Same version in. Fix `APP__BASE_URL` and every connector URL to internal FQDNs.
No config may still reference `20.244.26.112`.

## Phase 4 — Prove it

```bash
./scripts/stack-healthcheck.sh                  # target
./scripts/opencti-inventory.py --out out/inventory-after.json
make diff                                       # exit 0 = sign-off
```

Manual checks the numbers can't cover: a report attachment downloads (proves
`s3data`), search returns results without a reindex, every connector green with
no auth errors, a synthetic Wazuh alert produces an enriched alert, login works
on the new base URL.

## Phase 5 — Cut over and keep the rollback

- Update DNS / client bookmarks; announce the new base URL
- Keep Azure VM **deallocated, disks intact** for 30 days; keep the bundle and
  the volume tarballs
- Only after sign-off: delete snapshots and disks

## Phase 6 — Ongoing

- Elasticsearch snapshot repository from day one — indices cannot be rebuilt
  from any other store
- Quarterly restore drill; an untested backup is not a backup
- Updates: edit `images.txt` → let the Action build → carry → registry → bump tags
- Prefer LTS releases: fewer transfers into the gap
