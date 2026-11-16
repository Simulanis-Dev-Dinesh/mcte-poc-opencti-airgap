SHELL := /usr/bin/env bash
-include versions.env
export

.PHONY: azure-inventory opencti-inventory opencti-inventory-after healthcheck mirror diff backup wazuh-retarget

azure-inventory:
	./scripts/azure-inventory.sh

# SOURCE side. This is the baseline — run it on Azure, commit the result.
opencti-inventory:
	./scripts/opencti-inventory.py --out out/inventory-before.json

# TARGET side. Deliberately a separate target: reusing the one above on the
# target overwrites the baseline and makes `make diff` compare the target with
# itself, which always passes.
opencti-inventory-after:
	./scripts/opencti-inventory.py --out out/inventory-after.json

healthcheck:
	./scripts/stack-healthcheck.sh

mirror:
	DEST_PREFIX=$${DEST_PREFIX:-ghcr.io/$$(echo $${GITHUB_OWNER:-simulanis-dev-dinesh} | tr '[:upper:]' '[:lower:]')/opencti-airgap} ./scripts/mirror-images.sh

diff:
	@test -f out/inventory-before.json || { echo "missing out/inventory-before.json — run 'make opencti-inventory' on the SOURCE" >&2; exit 1; }
	@test -f out/inventory-after.json  || { echo "missing out/inventory-after.json — run 'make opencti-inventory-after' on the TARGET" >&2; exit 1; }
	./scripts/opencti-diff.py out/inventory-before.json out/inventory-after.json

backup:
	./scripts/backup-volumes.sh

# Wazuh retargeting. Dry run by default; add APPLY=1 to change anything.
#   make wazuh-retarget NEW_URL=https://opencti.internal.example SSH=manager@wazuh-server APPLY=1
#   make wazuh-retarget NEW_MANAGER=wazuh.internal.example APPLY=1
wazuh-retarget:
	@./scripts/wazuh-retarget.sh \
		$(if $(NEW_URL),--new-url '$(NEW_URL)',) \
		$(if $(NEW_MANAGER),--manager-address '$(NEW_MANAGER)',) \
		$(if $(SSH),--ssh '$(SSH)',) \
		$(if $(APPLY),--apply,)
