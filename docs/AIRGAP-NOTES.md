# Air-gap notes

## Why GHCR is safe here

GHCR is only the internet-side staging mirror. Image layers are public upstream
artefacts; no CTI data ever leaves. Nothing inside the gap resolves `ghcr.io` —
`compose/docker-compose.override.yml` rewrites every image to the internal
registry, and `load-into-registry.sh` is the only path in.

## XTM Composer

From 6.8 the platform can deploy connectors itself via `xtm-composer`, which
pulls from Docker Hub at runtime. In an air gap either:

- configure a private registry (`opencti.daemon.registry.server/username/password`), or
- skip the composer entirely and run connectors as static compose services
  (recommended for a first air-gapped deployment — every image is one you
  explicitly mirrored).

## Things that break silently

| Symptom | Cause |
|---|---|
| Connectors fail auth after cutover | `APP__ENCRYPTION_KEY` not carried over |
| ES will not start | `vm.max_map_count`, or esdata not owned by `1000:0` |
| Tokens/certs rejected | no internal NTP, clock drift |
| Search returns nothing | engine switched (ES <-> OpenSearch) or major version bumped during the move |
| Links point at old host | `APP__BASE_URL` not updated |
| Feed connectors red | expected — no egress; use diode or manual STIX import |
