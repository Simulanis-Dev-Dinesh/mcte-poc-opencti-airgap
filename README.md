# OpenCTI air-gap migration kit

Moving the OpenCTI platform from Azure (`SIMULANIS-IN` / `Opencti`) into the
air-gapped network, carrying all data, and keeping the Wazuh manager wired to it.

Three tools, three jobs — keep them separate:

| Tool | Job |
|---|---|
| Azure CLI | Freeze and prove the source: snapshots, network capture, consistent stop, bulk data egress |
| OpenCTI API (`scripts/opencti-inventory.py`) | Prove the *content* survived: golden numbers before, diff after |
| GitHub + GHCR | Config as code, and the repeatable image-mirror / bundle-release pipeline |

## Quickstart

```bash
make azure-inventory      # read-only inventory of the Azure side  -> out/azure/
make opencti-inventory    # golden numbers from the live platform   -> out/inventory-before.json
make healthcheck          # docker / ES / RabbitMQ / Redis / time / TLS state -> out/health-*/
make mirror               # mirror images.txt to GHCR + build oci bundle (needs internet)
make diff                 # after cutover: inventory-after.json vs inventory-before.json
```

## Layout

```
images.txt                     pinned image list (generate it from the source VM, do not guess)
versions.env                   target versions + non-secret settings
.env.template                  OpenCTI env skeleton — NEVER commit a real .env
scripts/azure-inventory.sh     everything to know about the Azure VM, read-only
scripts/stack-healthcheck.sh   runs on either host: containers, ES, RMQ, Redis, time, TLS
scripts/opencti-inventory.py   read-only GraphQL inventory (counts + config)
scripts/opencti-diff.py        compares two inventories, exits non-zero on drift
scripts/mirror-images.sh       skopeo -> GHCR with digest preservation + oci archives
scripts/load-into-registry.sh  inside the gap: oci archives -> internal registry
scripts/restore-volumes.sh     inside the gap: restore esdata/s3data/redisdata/amqpdata
scripts/backup-volumes.sh      on the source: consistent volume tarballs
.github/workflows/mirror-images.yml   scheduled bundle builder -> GitHub Release
docs/RUNBOOK.md                phased migration runbook
docs/COMMANDS.md               the full command reference
docs/WAZUH-INTEGRATION.md      the three Wazuh<->OpenCTI integration paths
```

## Non-negotiables

1. **Never migrate the VM image.** Migrate the compose stack onto a clean host;
   cloud-init / waagent / IMDS do not exist in the air gap.
2. **Stop the stack before snapshotting.** Elasticsearch must not be writing.
3. **Same version in, upgrade later.** Two changes at once is how migrations fail.
4. **Carry `APP__ENCRYPTION_KEY`.** Without it, encrypted secrets (SSO, connector
   credentials) are unreadable after the move.
5. **No secrets in this repo.** `.env.template` only. Retrieve anything from Key
   Vault before decommissioning the VM.
6. **Nothing inside the gap resolves `ghcr.io`.** GHCR is the internet-side
   staging mirror only.
