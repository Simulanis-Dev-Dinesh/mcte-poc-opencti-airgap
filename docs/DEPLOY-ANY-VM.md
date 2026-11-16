# Putting the bundle on any VM

This is the host-agnostic half of the migration. It works the same whether the
target is an air-gapped machine with no network at all, a staging VM on a
corporate LAN, or a cloud instance. The only things that change are how the
files arrive and where Docker comes from.

Everything below is done **on the target** unless a step says otherwise.

---

## 0. What the target needs

| Requirement | Why |
|---|---|
| Ubuntu 24.04 noble **amd64** (or matching packages) | `docker-offline.tgz` was built for that only. If the target differs, the packages are useless — check before you travel. |
| ≥ 30 GB free under the Docker data-root | Elasticsearch plus the image store. 100 GB is comfortable. |
| ≥ 8 GB RAM, 4 vCPU | The source ran 43 containers on a D8-class VM. |
| sudo | Loading images, restoring volumes, writing `daemon.json`. |
| The kit itself | `scripts/`, `Makefile`, `images.txt` — see step 1. |

No internet is required at any point on the air-gapped path.

---

## 1. Get the files onto the machine

You are moving two things: the **bundle** (~12 GB, 12 files) and the **kit**
(the repo, a few hundred KB). Pick whichever transfer fits your network.

### A. Both hosts can reach each other — rsync over SSH

```bash
rsync -avP --checksum ~/opencti-bundle/ user@target:/srv/opencti-bundle/
rsync -avP --checksum ./mcte-poc-opencti-airgap/ user@target:/srv/kit/
```

`--checksum` compares content rather than size and mtime, so a resumed or
partial transfer is caught. It is not a substitute for step 2.

### B. The target is behind a jump host

```bash
rsync -avP -e 'ssh -J jumpuser@jumphost' \
  ~/opencti-bundle/ user@target:/srv/opencti-bundle/
```

Same for the kit. If the jump host is the only host with outbound access, land
the files there first, then push them onward — two hops, checksum at the end.

### C. True air gap — removable media

1. Copy the bundle and the kit to the media.
2. `sync` and unmount cleanly. A pulled drive is a corrupted drive.
3. Carry `sha256sums.txt` **separately** from the media, and keep the gpg
   passphrase somewhere that is neither.
4. Log carrier, media serial, file count, hashes, sign-out and sign-in.
5. At the destination, mount **read-only**, copy off, unmount, then verify.

### D. Images only — an internal registry the target can already reach

If a registry inside the network already holds the images, skip
`xtm-images.tar` entirely:

```bash
LOCAL_REGISTRY=registry.internal:5000 BUNDLE_DIR=./bundle ./scripts/load-into-registry.sh
```

That is the only path that puts images in the gap without carrying the tar.

---

## 2. Verify before you touch anything

```bash
cd /srv/opencti-bundle
sha256sum -c sha256sums.txt
```

Every line must say `OK`. If the encrypted `.gpg` files were created after the
checksum file was generated, they are not covered — regenerate it first.

A clean copy on the laptop proves the laptop. This step proves the copy that
crossed. Do not skip it because the laptop passed.

---

## 3. Prepare the host

### Docker

Air-gapped — install from the carried packages:

```bash
tar -xzf docker-offline.tgz -C /tmp/docker-pkgs
sudo dpkg -i /tmp/docker-pkgs/*.deb
sudo systemctl enable --now docker
```

Online — use the distro repository or Docker's own, whichever your policy allows.

### Kernel and disk

```bash
# Elasticsearch will not start without this
echo 'vm.max_map_count=1048575' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# data-root on the large volume, not the OS disk
sudo mkdir -p /srv/docker
```

`/etc/docker/daemon.json`:

```json
{
  "data-root": "/srv/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

```bash
sudo systemctl restart docker
docker info -f '{{.DockerRootDir}}'    # must print /srv/docker
```

Without the log options, 43 containers will fill the disk with json logs and
nothing will tell you until it is full.

### Time

Point the host at internal NTP before starting anything. Clock drift breaks
tokens and TLS in ways that look like application bugs.

---

## 4. Load the images

```bash
cd /srv/opencti-bundle
docker load -i xtm-images.tar     # expect 40 images
docker load -i alpine.tar         # needed by the restore commands
docker images --format '{{.Repository}}:{{.Tag}}' | wc -l
```

If the count is not 40, stop and find out which image is missing. Do not start
the stack and hope.

---

## 5. Restore the volumes

The tarballs in the bundle are flat. The restore script expects a directory
containing one `*.tgz` per volume:

```bash
mkdir -p /srv/volumes
cd /srv/volumes
for f in xtm_esdata xtm_s3data xtm_redisdata xtm_amqpdata \
         xtm_pgsqlxtmonedata xtm_rsakeys; do
  tar -xzf /srv/opencti-bundle/$f.tgz -C /srv/volumes 2>/dev/null || true
done
ls *.tgz        # one per volume, named xtm_<vol>.tgz
```

Then:

```bash
cd /srv/kit
SRC=/srv/volumes PROJECT=xtm ./scripts/restore-volumes.sh
```

`PROJECT=xtm` matters. The tarballs are already `xtm_esdata.tgz` and so on;
restoring under any other project name writes the data into a volume the stack
never mounts, and the platform then starts empty with no error at all.

The script finishes by setting `xtm_esdata` ownership to `1000:0`. If it cannot
find that path it exits non-zero — read the error rather than proceeding.

---

## 6. Config and environment

```bash
cd /srv/kit
tar -xzf /srv/opencti-bundle/compose-config.tgz -C /srv/
tar -xzf /srv/opencti-bundle/nginx-config.tgz   -C /srv/
```

Place `.env` beside the compose files, then change every address that points at
the old world:

- `OPENCTI_HOST` / `XTM_ONE_HOST` / `APP__BASE_URL` → the internal FQDN
- any `*_EXTERNAL_SCHEME`
- every connector URL

Then prove you got them all:

```bash
grep -rnE '([0-9]{1,3}\.){3}[0-9]{1,3}' /srv/.env /srv/docker-compose*.yml
```

Nothing from the public range should remain.

Replace the TLS certificate with one from the internal CA, keeping the same
filenames so the compose mount still resolves.

---

## 7. Start it

Both files. `docker-compose.https.yml` is where `nginx` and the HTTPS front end
live — one `-f` gives you a platform with no web UI and no obvious reason why.

```bash
cd /srv
docker compose -f docker-compose.yml -f docker-compose.https.yml up -d
docker compose ps          # expect 43 containers
```

---

## 8. Prove it

```bash
cd /srv/kit
make healthcheck
make opencti-inventory-after
make diff                  # exit 0 = sign-off
```

Then the checks no number covers:

- a report attachment downloads (proves `s3data` restored)
- search returns results without a reindex
- login works on the new base URL
- every connector is green with no auth errors
- a synthetic Wazuh alert produces an enriched alert

---

## 9. When it goes wrong

| Symptom | Cause |
|---|---|
| Platform up, zero data | restored under the wrong `PROJECT` — check `docker volume ls` |
| Elasticsearch will not start | `vm.max_map_count`, or `esdata` not owned by `1000:0` |
| No web UI | started without `docker-compose.https.yml` |
| Fewer than 40 images | incomplete `docker load`, or a bad transfer |
| Connectors fail auth | encryption key not carried over |
| Tokens and certs rejected | clock drift, no NTP |
| Disk fills over days | no `daemon.json` log rotation |
| `make diff` passes suspiciously easily | the source inventory was run on this host and overwrote the baseline |
