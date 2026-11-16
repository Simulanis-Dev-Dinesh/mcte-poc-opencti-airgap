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
