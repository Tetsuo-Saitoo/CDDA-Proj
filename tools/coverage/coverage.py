"""Art coverage report (block H2).

Lists every CDDA terrain / furniture / trap / item / monster / vehicle part id, estimates how often it spawns,
and reports which step of the fallback chain (contracts/assets.md) gives it art. Uncovered ids with the highest
spawn weight are what the art team should make next.

Usage:
    python -I tools/coverage/coverage.py --ids contracts/mock/id_tables.json --data cdda/data/json
        [--registry assets/registry] [--out tools/out]

    --ids   the bridge's id tables file (contracts/id_tables.md): the ids, names and looks_like exactly as the
            game loaded them, mods included. The mock is in contracts/mock; a fresh one comes from
            `fp3d-headless <bubble.json> 1 2 <id_tables.json>` or the client's get_id_tables_json().
    --data  CDDA's data/json (more --data for mods): the spawn weights. Without --ids it is also where the ids
            come from, read straight from the JSON as before (it then follows copy-from as well as looks_like;
            the client follows looks_like only).
    One of the two is needed. With --ids alone there are no spawn weights and every id counts the same.

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
MAX_IDS_FILE_BYTES = 256 * 1024 * 1024  # id tables of a game with many mods: tens of MB; the mock is 3 MB
MAX_IDS_ROWS = 1_000_000  # per table
MAX_ID_CHARS = 256
NULL_IDS = {"t_null", "f_null", "tr_null", "mon_null", "null"}  # the tables list CDDA's "nothing" ids too
MAX_CHAIN = 16
# id tables file: table name -> the kind this report uses
ID_TABLES = {
    "ter": "terrain",
    "furn": "furniture",
    "trap": "trap",
    "itype": "item",
    "mtype": "monster",
    "vpart": "vehicle_part",
}
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


def load_id_tables(path):
    """Read the bridge's id tables file (contracts/id_tables.md) -> (kind -> id -> row, generation, rows skipped).

    These are the ids the game itself loaded: mods included, abstract types gone, `looks_like` as the game has it.
    The file is untrusted like any other input: its size is capped, and a table or row of the wrong shape is skipped.
    """
    if os.path.getsize(path) > MAX_IDS_FILE_BYTES:
        raise ValueError(f"{path}: larger than {MAX_IDS_FILE_BYTES // (1024 * 1024)} MB")
    with open(path, encoding="utf-8") as f:
        tables = json.load(f)
    if not isinstance(tables, dict):
        raise ValueError(f"{path}: not an id tables file")
    defs = {k: {} for k in KINDS.values()}
    skipped = 0
    for table, kind in ID_TABLES.items():
        rows = tables.get(table)
        if not isinstance(rows, list):
            continue
        for row in rows[:MAX_IDS_ROWS]:
            cid = row.get("id") if isinstance(row, dict) else None
            if not isinstance(cid, str) or not cid or len(cid) > MAX_ID_CHARS:
                skipped += 0 if isinstance(row, dict) and cid == "" else 1  # index 0 is the empty "none" row
                continue
            if cid in NULL_IDS:
                continue  # "nothing here": it needs no art
            name = row.get("name")
            looks = row.get("looks_like")
            defs[kind][cid] = {
                "id": cid,
                "name": name if isinstance(name, str) else "",
                "looks_like": looks if isinstance(looks, str) and looks else None,
            }
        skipped += max(0, len(rows) - MAX_IDS_ROWS)
    gen = tables.get("generation")
    return defs, gen if isinstance(gen, int) else 0, skipped


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


def usable(obj, kind):
    """Art the client can show for this kind: terrain needs a mesher or model, props a placeholder or model."""
    if obj is None:
        return False
    keys = ("mesher", "model") if kind == "terrain" else ("placeholder", "model")
    return any(isinstance(obj.get(k), str) and obj.get(k) for k in keys)


def resolve(data, kind, cid, reg):
    """Return (status, via) following the fallback chain from contracts/assets.md (steps 1-2)."""
    if usable(reg.get(cid), kind):
        return "exact", cid
    cur, seen = data.defs[kind].get(cid), {cid}
    for _ in range(MAX_CHAIN):
        if cur is None:
            break
        nxt = cur.get("looks_like") if isinstance(cur.get("looks_like"), str) else None
        nxt = nxt or (cur.get("copy-from") if isinstance(cur.get("copy-from"), str) else None)
        if not nxt or nxt in seen:
            break
        if usable(reg.get(nxt), kind):
            return "looks_like", nxt
        seen.add(nxt)
        cur = data.defs[kind].get(nxt) or data.abstracts.get(nxt)
    return "placeholder", ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", help="CDDA data/json folder (add mods with more --data); needed without --ids, and "
                    "with --ids it gives the spawn weights", action="append")
    ap.add_argument("--ids", help="the bridge's id tables file: the ids, names and looks_like the game loaded")
    ap.add_argument("--registry", default="assets/registry")
    ap.add_argument("--out", default="tools/out")
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()
    if not a.data and not a.ids:
        ap.error("give --ids, --data, or both")

    data = Data()
    for root in a.data or []:
        for obj in load_objects(root):
            data.add(obj)
    if a.ids:
        try:
            defs, generation, skipped = load_id_tables(a.ids)
        except (OSError, ValueError, RecursionError) as e:
            sys.exit(f"cannot read the id tables: {e}")
        # The game's own list replaces what was read from JSON; the tables carry no abstract types and no
        # copy-from, so the fallback chain follows looks_like only, as the client does.
        data.defs = defs
        data.abstracts = {}
        print(f"ids: {sum(len(d) for d in defs.values())} from {a.ids} (generation {generation})"
              + (f", {skipped} rows skipped" if skipped else ""))
        if not a.data:
            print("no --data: spawn weights are 0, so the percentages count every id the same")
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
        # A kind with no spawn weights at all (no --data): every id counts the same.
        weigh = (lambda r: r[2]) if any(r[2] for r in rows) else (lambda r: 1.0)
        total = sum(weigh(r) for r in rows) or 1.0
        exact = sum(weigh(r) for r in rows if r[3] == "exact") / total * 100
        anyc = sum(weigh(r) for r in rows if r[3] != "placeholder") / total * 100
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
