#!/usr/bin/env python3
"""Compare two inventories produced by opencti-inventory.py.

    ./scripts/opencti-diff.py out/inventory-before.json out/inventory-after.json

Exit code 0 = match (within tolerance), 1 = drift. Use it as the cutover gate.
"""
import json, sys, argparse


def load(p):
    with open(p) as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--tolerance", type=int, default=0, help="allowed absolute drift per count")
    a = ap.parse_args()

    b, af = load(a.before), load(a.after)
    bad = 0

    print(f"{'type':<34}{'before':>10}{'after':>10}{'delta':>10}")
    print("-" * 64)
    for t in sorted(set(b["counts"]) | set(af["counts"])):
        nb, na = b["counts"].get(t, 0), af["counts"].get(t, 0)
        d = na - nb
        flag = "" if abs(d) <= a.tolerance else "  <-- DRIFT"
        if flag:
            bad += 1
        print(f"{t:<34}{nb:>10}{na:>10}{d:>+10}{flag}")

    print()
    for k in sorted(set(b["lists"]) | set(af["lists"])):
        sb = {x.get("name") or x.get("definition") or x.get("id") for x in b["lists"].get(k, [])}
        sa = {x.get("name") or x.get("definition") or x.get("id") for x in af["lists"].get(k, [])}
        missing, extra = sb - sa, sa - sb
        status = "ok" if not missing and not extra else f"missing={sorted(missing)[:5]} extra={sorted(extra)[:5]}"
        # Extra objects on the target matter too: a double-restored volume or
        # a re-imported bundle must fail the gate, not pass it.
        if missing or extra:
            bad += 1
        print(f"{k:<34}{len(sb):>10}{len(sa):>10}   {status}")

    print()
    if b.get("errors"):
        print(f"note: {len(b['errors'])} unsupported queries on the source")
    if af.get("errors"):
        print(f"note: {len(af['errors'])} unsupported queries on the target")
    print("RESULT:", "MATCH" if bad == 0 else f"{bad} difference(s) — investigate before sign-off")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
