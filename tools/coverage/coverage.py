"""Art coverage report (block H2).

Lists every CDDA terrain / furniture / trap / item / monster / vehicle part id, estimates how often it spawns,
and reports which step of the fallback chain (contracts/assets.md) gives it art. Uncovered ids with the highest
spawn weight are what the art team should make next.

Usage:
    python -I tools/coverage/coverage.py --data cdda/data/json --registry assets/registry [--out tools/out]

Spawn weights are heuristics, good for ranking only:
    terrain/furniture  map squares placed by mapgen rows (via inline maps and palettes) + references
    trap               references in mapgen/palettes
    item               sum of item_group probabilities
    monster            sum of monstergroup weights
    vehicle_part       parts placed in vehicle prototypes
"""
import argparse
import collections
import csv
import json
import os
import sys

MAX_FILE_BYTES = 64 * 1024 * 1024  # data is untrusted (mods): skip absurd files
MAX_CHAIN = 16
KINDS = {
    "terrain": "terrain",
    "furniture": "furniture",
    "trap": "trap",
    "ITEM": "item",
    "MONSTER": "monster",
    "vehicle_part": "vehicle_part",
}


def load_objects(root):
    """Yield every JSON object under root. Bad files are reported and skipped."""
    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".json"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getsize(path) > MAX_FILE_BYTES:
                    print(f"skip (too large): {path}", file=sys.stderr)
                    continue
                with open(path, encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, ValueError, RecursionError) as e:
                print(f"skip (unreadable): {path}: {e}", file=sys.stderr)
                continue
            for obj in data if isinstance(data, list) else [data]:
                if isinstance(obj, dict):
                    yield obj


def name_of(obj):
    n = obj.get("name")
    if isinstance(n, dict):
        n = n.get("str") or n.get("str_sp") or ""
    return n if isinstance(n, str) else ""


def walk_strings(node, out, depth=0):
    """Count every string inside a JSON node (used for 'is referenced' weights)."""
    if depth > 64:
        return
    if isinstance(node, str):
        out[node] += 1
    elif isinstance(node, list):
        for v in node:
            walk_strings(v, out, depth + 1)
    elif isinstance(node, dict):
        for v in node.values():
            walk_strings(v, out, depth + 1)


def mapping_choices(value):
    """A palette/mapgen char mapping -> [(id, share)]. Handles str, [id, w] lists and param fallbacks."""
    if isinstance(value, str):
        return [(value, 1.0)]
    if isinstance(value, dict):
        fb = value.get("fallback")
        return [(fb, 1.0)] if isinstance(fb, str) else []
    if isinstance(value, list):
        picks = []
        for v in value:
            if isinstance(v, str):
                picks.append((v, 1.0))
            elif isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and isinstance(v[1], (int, float)):
                picks.append((v[0], float(v[1])))
        total = sum(w for _, w in picks) or 1.0
        return [(i, w / total) for i, w in picks]
    return []


class Data:
    def __init__(self):
        self.defs = {k: {} for k in KINDS.values()}  # kind -> id -> obj
        self.abstracts = {}  # abstract id -> obj (copy-from targets)
        self.palettes = {}
        self.mapgens = []
        self.item_groups = []
        self.mon_groups = []
        self.vehicles = []

    def add(self, obj):
        t = obj.get("type")
        if t in KINDS:
            if isinstance(obj.get("abstract"), str):
                self.abstracts[obj["abstract"]] = obj
            elif isinstance(obj.get("id"), str):
                self.defs[KINDS[t]][obj["id"]] = obj
        elif t == "palette" and isinstance(obj.get("id"), str):
            self.palettes[obj["id"]] = obj
        elif t == "mapgen":
            self.mapgens.append(obj)
        elif t == "item_group":
            self.item_groups.append(obj)
        elif t == "monstergroup":
            self.mon_groups.append(obj)
        elif t == "vehicle":
            self.vehicles.append(obj)


def palette_lookup(data, palette_ids, key, char, seen=None, depth=0):
    """Resolve char in the given palettes (later palettes win, nested palettes searched too)."""
    seen = seen if seen is not None else set()
    for pid in reversed(palette_ids):
        if not isinstance(pid, str) or pid in seen or depth > 8:
            continue
        seen.add(pid)
        pal = data.palettes.get(pid)
        if not pal:
            continue
        m = pal.get(key)
        if isinstance(m, dict) and char in m:
            return m[char]
        nested = [p for p in pal.get("palettes", []) if isinstance(p, str)]
        hit = palette_lookup(data, nested, key, char, seen, depth + 1)
        if hit is not None:
            return hit
    return None


def spawn_weights(data):
    w = {k: collections.Counter() for k in KINDS.values()}

    refs = collections.Counter()
    for obj in data.mapgens:
        walk_strings(obj.get("object"), refs)
    for obj in data.palettes.values():
        walk_strings(obj, refs)
    for kind in ("terrain", "furniture", "trap"):
        for i in data.defs[kind]:
            w[kind][i] += refs[i]

    for mg in data.mapgens:
        o = mg.get("object")
        if not isinstance(o, dict) or not isinstance(o.get("rows"), list):
            continue
        scale = mg.get("weight", 1000)
        scale = scale / 1000.0 if isinstance(scale, (int, float)) and scale > 0 else 1.0
        chars = collections.Counter(c for row in o["rows"] if isinstance(row, str) for c in row)
        pals = [p for p in o.get("palettes", []) if isinstance(p, str)]
        unfilled = 0
        for ch, n in chars.items():
            for key, kind in (("terrain", "terrain"), ("furniture", "furniture")):
                own = o.get(key)
                val = own[ch] if isinstance(own, dict) and ch in own else palette_lookup(data, pals, key, ch)
                if val is None:
                    if key == "terrain":
                        unfilled += n
                    continue
                for i, share in mapping_choices(val):
                    w[kind][i] += n * share * scale
        if isinstance(o.get("fill_ter"), str):
            w["terrain"][o["fill_ter"]] += unfilled * scale

    def items_in(node, depth=0):
        if depth > 32:
            return
        if isinstance(node, list):
            if len(node) == 2 and isinstance(node[0], str) and isinstance(node[1], (int, float)):
                w["item"][node[0]] += node[1]
                return
            for v in node:
                items_in(v, depth + 1)
        elif isinstance(node, dict):
            if isinstance(node.get("item"), str):
                p = node.get("prob", 100)
                w["item"][node["item"]] += p if isinstance(p, (int, float)) else 100
            for k in ("items", "entries", "distribution", "collection"):
                if k in node:
                    items_in(node[k], depth + 1)
        elif isinstance(node, str):
            w["item"][node] += 100

    for g in data.item_groups:
        items_in({k: g[k] for k in ("items", "entries") if k in g})

    for g in data.mon_groups:
        for m in g.get("monsters", []) if isinstance(g.get("monsters"), list) else []:
            if isinstance(m, dict) and isinstance(m.get("monster"), str):
                wt = m.get("weight", m.get("freq", 1))
                w["monster"][m["monster"]] += wt if isinstance(wt, (int, float)) else 1
        if isinstance(g.get("default"), str):
            w["monster"][g["default"]] += 1

    for v in data.vehicles:
        for p in v.get("parts", []) if isinstance(v.get("parts"), list) else []:
            if not isinstance(p, dict):
                continue
            ids = [p["part"]] if isinstance(p.get("part"), str) else []
            ids += [x if isinstance(x, str) else x.get("part") for x in p.get("parts", []) if isinstance(x, (str, dict))]
            for i in ids:
                if isinstance(i, str):
                    w["vehicle_part"][i.split("#")[0]] += 1
    return w


def load_registry(root):
    reg = {}
    if not os.path.isdir(root):
        return reg
    for obj in load_objects(root):
        if obj.get("type") != "fp3d_model":
            continue
        ids = obj.get("id")
        for i in ids if isinstance(ids, list) else [ids]:
            if isinstance(i, str):
                reg[i] = obj
    return reg


def resolve(data, kind, cid, reg):
    """Return (status, via) following the fallback chain from contracts/assets.md (steps 1-2)."""
    if cid in reg:
        return "exact", cid
    cur, seen = data.defs[kind].get(cid), {cid}
    for _ in range(MAX_CHAIN):
        if cur is None:
            break
        nxt = cur.get("looks_like") if isinstance(cur.get("looks_like"), str) else None
        nxt = nxt or (cur.get("copy-from") if isinstance(cur.get("copy-from"), str) else None)
        if not nxt or nxt in seen:
            break
        if nxt in reg:
            return "looks_like", nxt
        seen.add(nxt)
        cur = data.defs[kind].get(nxt) or data.abstracts.get(nxt)
    return "placeholder", ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="CDDA data/json folder (add mods with more --data)", action="append")
    ap.add_argument("--registry", default="assets/registry")
    ap.add_argument("--out", default="tools/out")
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()

    data = Data()
    for root in a.data:
        for obj in load_objects(root):
            data.add(obj)
    reg = load_registry(a.registry)
    weights = spawn_weights(data)
    os.makedirs(a.out, exist_ok=True)

    print(f"registry entries: {len(reg)}")
    known = set().union(*data.defs.values())
    unknown = sorted(i for i in reg if i not in known and not i.startswith("generic_"))
    if unknown:
        print(f"WARNING: {len(unknown)} registry ids not in CDDA data: {', '.join(unknown[:20])}")
    print(f"{'kind':<13}{'ids':>7}{'exact%':>9}{'w/ fallback%':>14}   (weighted by spawn frequency)")
    for kind, defs in data.defs.items():
        rows = []
        for cid, obj in defs.items():
            status, via = resolve(data, kind, cid, reg)
            rows.append((cid, name_of(obj), round(weights[kind][cid], 2), status, via))
        rows.sort(key=lambda r: -r[2])
        total = sum(r[2] for r in rows) or 1.0
        exact = sum(r[2] for r in rows if r[3] == "exact") / total * 100
        anyc = sum(r[2] for r in rows if r[3] != "placeholder") / total * 100
        print(f"{kind:<13}{len(rows):>7}{exact:>9.1f}{anyc:>14.1f}")
        with open(os.path.join(a.out, f"coverage_{kind}.csv"), "w", newline="", encoding="utf-8") as f:
            cw = csv.writer(f)
            cw.writerow(["id", "name", "spawn_weight", "status", "via"])
            cw.writerows(rows)
        todo = [r for r in rows if r[3] == "placeholder"][: a.top]
        if todo:
            print("    next to make: " + ", ".join(r[0] for r in todo))


if __name__ == "__main__":
    main()
