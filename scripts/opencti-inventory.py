#!/usr/bin/env python3
"""Read-only golden-number inventory of an OpenCTI platform.

Pure GraphQL over requests — no pycti dependency, so it runs from any jump host.

    export OPENCTI_URL=https://opencti.internal.example
    export OPENCTI_TOKEN=<token>
    ./scripts/opencti-inventory.py --out out/inventory-before.json

Every query is independently guarded: a field this platform version does not
expose is recorded under "errors" instead of killing the run.
"""
import argparse, json, os, sys, datetime
import urllib3, requests

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

ENTITY_TYPES = [
    "Indicator", "Malware", "Intrusion-Set", "Threat-Actor", "Campaign",
    "Tool", "Vulnerability", "Report", "Malware-Analysis", "Attack-Pattern",
    "Course-Of-Action", "Infrastructure", "Observed-Data", "Grouping",
    "Incident", "Case-Incident", "Narrative", "Channel", "Event",
    "Stix-Core-Relationship", "Stix-Sighting-Relationship",
    "Stix-Cyber-Observable", "Artifact", "IPv4-Addr", "Domain-Name", "Url",
    "StixFile", "User-Account", "Hostname", "Email-Addr",
]

COUNT_Q = """
query Count($types: [String!]) {
  stixCoreObjectsNumber(types: $types) { total }
}
"""

LIST_QUERIES = {
    "connectors": "query { connectors { edges { node { id name connector_type active auto } } } }",
    "users": "query { users { edges { node { id name user_email } } } }",
    "groups": "query { groups { edges { node { id name } } } }",
    "roles": "query { roles { edges { node { id name } } } }",
    "markingDefinitions": "query { markingDefinitions { edges { node { id definition } } } }",
    "taxiiCollections": "query { taxiiCollections { edges { node { id name } } } }",
    "streamCollections": "query { streamCollections { edges { node { id name } } } }",
    "retentionRules": "query { retentionRules { edges { node { id name max_retention } } } }",
    "playbooks": "query { playbooks { edges { node { id name } } } }",
}


class Client:
    def __init__(self, url, token, verify):
        self.url = url.rstrip("/") + "/graphql"
        self.headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        self.verify = verify

    def q(self, query, variables=None):
        r = requests.post(self.url, json={"query": query, "variables": variables or {}},
                          headers=self.headers, verify=self.verify, timeout=120)
        r.raise_for_status()
        body = r.json()
        if body.get("errors"):
            raise RuntimeError(json.dumps(body["errors"])[:400])
        return body["data"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get("OPENCTI_URL"))
    ap.add_argument("--token", default=os.environ.get("OPENCTI_TOKEN"))
    ap.add_argument("--out", default="out/inventory.json")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (temporary, self-signed certs only)")
    a = ap.parse_args()
    if not a.url or not a.token:
        sys.exit("set OPENCTI_URL and OPENCTI_TOKEN")

    c = Client(a.url, a.token, verify=not a.insecure)
    inv = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "url": a.url,
        "counts": {},
        "lists": {},
        "errors": {},
    }

    # counts
    for t in ENTITY_TYPES:
        try:
            d = c.q(COUNT_Q, {"types": [t]})
            n = (d.get("stixCoreObjectsNumber") or {}).get("total")
            if n:
                inv["counts"][t] = n
        except Exception as e:
            inv["errors"][f"count:{t}"] = str(e)

    # config inventory
    for name, q in LIST_QUERIES.items():
        try:
            d = c.q(q)
            edges = (d.get(name) or {}).get("edges") or []
            inv["lists"][name] = [e["node"] for e in edges]
        except Exception as e:
            inv["errors"][f"list:{name}"] = str(e)

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(inv, f, indent=2, sort_keys=True)

    total = sum(inv["counts"].values())
    print(f"wrote {a.out}")
    print(f"{'type':<34}{'count':>10}")
    for t, n in sorted(inv["counts"].items(), key=lambda kv: -kv[1]):
        print(f"{t:<34}{n:>10}")
    print(f"{'TOTAL':<34}{total:>10}")
    for k in ("connectors", "users", "groups", "roles", "markingDefinitions",
              "taxiiCollections", "streamCollections", "retentionRules", "playbooks"):
        if k in inv["lists"]:
            print(f"{k:<34}{len(inv['lists'][k]):>10}")
    if inv["errors"]:
        print(f"\n{len(inv['errors'])} query/queries unsupported on this version (see 'errors' in JSON)")


if __name__ == "__main__":
    main()
