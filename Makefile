SHELL := /usr/bin/env bash
-include versions.env
export

.PHONY: azure-inventory opencti-inventory healthcheck mirror diff backup

azure-inventory:
	./scripts/azure-inventory.sh

opencti-inventory:
	./scripts/opencti-inventory.py --out out/inventory-before.json

healthcheck:
	./scripts/stack-healthcheck.sh

mirror:
	DEST_PREFIX=$${DEST_PREFIX:-ghcr.io/$$(echo $${GITHUB_OWNER:-simulanis-dev-dinesh} | tr '[:upper:]' '[:lower:]')/opencti-airgap} ./scripts/mirror-images.sh

diff:
	./scripts/opencti-diff.py out/inventory-before.json out/inventory-after.json

backup:
	./scripts/backup-volumes.sh
