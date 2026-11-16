# OpenCTI air-gap migration kit

Moving the OpenCTI platform off its current host into an air-gapped network,
carrying all the data, and keeping the Wazuh manager wired to it. Host-agnostic:
the same steps work for a cloud VM, a LAN host, or a machine with no network.

Three tools, three jobs — keep them separate:

| Tool | Job |
|---|---|
| Docker + the host itself | Freeze and prove the source: consistent stop, volume tarballs, disk snapshot |
| OpenCTI API (`scripts/opencti-inventory.py`) | Prove the *content* survived: golden numbers before, diff after |
| GitHub + GHCR | Config as code, and the repeatable image-mirror / bundle-release pipeline |

## Quickstart

Commands are grouped by **where they run**. Running one on the wrong host is the
most common way this migration goes wrong without saying anything.

### On the source host

```bash
make opencti-inventory    # golden numbers from the live platform      -> out/inventory-before.json
make backup               # consistent volume tarballs                -> ./volumes/
make healthcheck          # containers, object storage, ES, RMQ, Redis, time, TLS -> out/health-*/
```

### On an internet-connected host

```bash
make mirror               # images.txt -> GHCR + oci archives (needs skopeo and network)
```

### At the target — inside the air gap

```bash
LOCAL_REGISTRY=registry.internal:5000 ./scripts/load-into-registry.sh
SRC=./volumes PROJECT=xtm ./scripts/restore-volumes.sh
docker compose -f docker-compose.yml -f docker-compose.https.yml up -d
make healthcheck
make opencti-inventory-after   # golden numbers from the TARGET -> out/inventory-after.json
make diff                      # exit 0 = sign-off
```

### Whenever a Wazuh address changes

Dry run unless you pass `APPLY=1`. Works locally on the manager, or remotely
with `SSH=manager@wazuh-server`.

```bash
make wazuh-retarget NEW_URL=https://opencti.internal.example SSH=manager@wazuh-server
make wazuh-retarget NEW_MANAGER=wazuh.internal.example APPLY=1
```

## Layout

```
Makefile                       every entry point; read it before running anything by hand
images.txt                     pinned image list (generate from the source VM, never guess)
versions.env                   target versions + non-secret settings
.env.template                  env skeleton — NEVER commit a real .env
compose/docker-compose.override.yml  air-gap override; confirm service names before use

scripts/backup-volumes.sh      on the source: consistent volume tarballs
scripts/bundle-to-media.sh     copy the bundle to a drive, verified on the drive
scripts/stack-healthcheck.sh   runs on either host: containers, storage, ES, RMQ, Redis, time, TLS
scripts/opencti-inventory.py   read-only GraphQL inventory (counts + config)
scripts/opencti-diff.py        compares two inventories; exits non-zero on drift OR extras
scripts/mirror-images.sh       skopeo -> GHCR, digests preserved and verified, + oci archives
scripts/load-into-registry.sh  inside the gap: oci archives -> internal registry
scripts/restore-volumes.sh     inside the gap: every *.tgz -> its volume, then the esdata chown
scripts/wazuh-retarget.sh      repoint the Wazuh integration, or move agents to a new manager

.github/workflows/mirror-images.yml   weekly bundle builder -> GitHub Release
docs/DEPLOY-ANY-VM.md          put the bundle on any VM: air-gapped, LAN, or cloud
docs/RUNBOOK.md                phased migration runbook
docs/COMMANDS.md               the full command reference
docs/WAZUH-INTEGRATION.md      the three Wazuh <-> OpenCTI integration paths
docs/AIRGAP-NOTES.md           GHCR rationale, composer caveat, silent-failure table
```

## Non-negotiables

1. **Never migrate the VM image.** Migrate the compose stack onto a clean host;
   cloud-init / waagent / IMDS do not exist in the air gap.
2. **Stop the stack before snapshotting.** Elasticsearch must not be writing.
3. **Same version in, upgrade later.** Two changes at once is how migrations fail.
4. **Carry the encryption key.** XTM One calls it `OPENCTI_ENCRYPTION_KEY`, older
   configs `APP__ENCRYPTION_KEY`. Lose it and every encrypted connector
   credential, SSO setting and stored secret is unreadable on the other side.
5. **`PROJECT=xtm`, and both compose files.** The compose project is `xtm`, so
   the volume tarballs are already `xtm_esdata.tgz` and so on — restoring under a
   different project writes the data to a volume the stack never mounts, and the
   platform starts empty with no error. And `docker-compose.https.yml` is where
   `nginx` lives: one `-f` gives you a platform with no web UI.
6. **The source-side inventory never runs on the target.** `make opencti-inventory`
   writes the baseline. Running it on the target overwrites that baseline, and
   the diff then compares the target with itself and always passes.
7. **Verify at the receiving end, not on the laptop.** A clean laptop copy proves
   the laptop. `sha256sum -c` on the target, before a single volume is restored.
8. **The data bundle never goes in git — and neither do secrets.** GitHub blocks
   files over 100 MiB and LFS tops out well below `xtm-images.tar`; more to the
   point, the ES data is TLP-marked intelligence and does not belong on any
   third-party host. Method in the repo, data on encrypted media. `.env.template`
   only, ever.
9. **Nothing inside the gap resolves `ghcr.io`.** GHCR is the internet-side
   staging mirror only; the internal registry is the only image source in the gap.
10. **The Wazuh integration fails silently.** No output in `integrations.log`
    looks identical to "no IoCs matched". Trigger a real alert and confirm a line
    appears — every time, not just at cutover.
