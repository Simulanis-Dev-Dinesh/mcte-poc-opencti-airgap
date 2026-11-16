# Wazuh <-> OpenCTI wiring

Three directions. Pick deliberately — they solve different problems.

## 1. Wazuh -> OpenCTI: enrich alerts (per-alert lookup)

Wazuh's `integratord` calls a `custom-opencti` script for nominated rule groups;
the script queries OpenCTI GraphQL for matching observables/indicators and writes
an enriched event back into the manager socket, where rules raise the alert.

```xml
<!-- /var/ossec/etc/ossec.conf -->
<ossec_config>
  <integration>
    <name>custom-opencti</name>
    <group>sysmon,suricata,web,syscheck,sshd</group>
    <hook_url>https://opencti.internal.example/graphql</hook_url>
    <api_key>REPLACE-WITH-DEDICATED-TOKEN</api_key>
    <alert_format>json</alert_format>
  </integration>
</ossec_config>
```

```bash
install -o root -g wazuh -m 750 custom-opencti custom-opencti.py /var/ossec/integrations/
systemctl restart wazuh-manager
tail -f /var/ossec/logs/integrations.log
```

Notes: dedicated least-privilege OpenCTI user, never the admin token. Keep the
rule-group list narrow — this path is synchronous per alert. Hook URL must be the
internal FQDN after the move.

## 2. OpenCTI -> Wazuh: detect on indicators (CDB lists)

Export indicators on a schedule into CDB lists and match them in Wazuh rules.
Better at scale than per-alert lookups.

```bash
# /var/ossec/etc/lists/opencti_ips, opencti_domains, opencti_file_hashes
# format: value:opencti
```

```xml
<!-- /var/ossec/etc/ossec.conf -->
<ossec_config>
  <ruleset>
    <list>etc/lists/opencti_ips</list>
    <list>etc/lists/opencti_domains</list>
    <list>etc/lists/opencti_file_hashes</list>
  </ruleset>
</ossec_config>
```

IPv6 keys must be quoted (`"2001:db8::1":opencti`) because `:` is the CDB separator.

## 3. OpenCTI -> Wazuh indexer: context lookup

The `opencti-wazuh-connector` enrichment queries Wazuh's OpenSearch for alert
context. Its own docs mark it early alpha — do not put it on the critical path.
If you do run it: read-only OpenSearch user with the `readall` backend role, and
a CA the connector trusts (do not disable TLS verification).

## Air-gap specifics

- Keep `wazuh-indexer` on its own VM. Never point it at OpenCTI's Elasticsearch.
- Replace every public IP (20.244.x.x) with internal DNS names in ossec.conf,
  connector env vars and OpenCTI playbooks.
- Time sync matters on both sides: internal NTP for both manager and OpenCTI host.
- Firewall: manager -> OpenCTI 443 only; OpenCTI connector -> indexer 9200 only.

## Retargeting — do it from the repo

`scripts/wazuh-retarget.sh` covers the two address changes this integration
needs. Both are dry runs until you pass `--apply`.

### OpenCTI moved to a new URL

```bash
./scripts/wazuh-retarget.sh --new-url https://opencti.internal.example
./scripts/wazuh-retarget.sh --new-url https://opencti.internal.example --apply
```

Run it on the manager, or from your workstation with `--ssh manager@wazuh-server`.
It timestamps a backup of `ossec.conf` and `opencti.env`, rewrites `<hook_url>`
and `OPENCTI_URL`, restarts the manager, then watches `integrations.log`.

It never touches `OPENCTI_TOKEN` — the token keeps working because the platform
data is restored intact. Rotate it separately.

### The manager itself moved

If the manager's address changes, every agent still points at the old one and
stops reporting. The script writes a managed block into the centralised config:

```bash
./scripts/wazuh-retarget.sh --manager-address wazuh.internal.example --apply
```

The block sits between `<!-- BEGIN opencti-airgap:manager-address -->` and
`<!-- END opencti-airgap:manager-address -->`, so re-running it replaces the
block in place rather than appending. Agents pick it up on their next connection.

Order of preference for an estate-wide move: reuse the same IP in the new
network (no change at all), then a DNS name in agent configs (one DNS edit), and
only then pushing centralised config. Settle it before cutover night — this is
not a same-evening operation.
