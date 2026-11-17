"""Converts the chosen models of Kenney's CC0 kits into CDDA-3D models (docs/MODELS.md, assets/models/LICENSE.md).
The kits are unpacked by hand under tools/out/cc0 (gitignored): kenney_food-kit, kenney_survival-kit and
kenney_furniturePack, each with its files/ folder as shipped. Their files are untrusted data: only bytes are
read, nothing in them is run or followed, and no image is loaded from a path a file names (each kit's colormap
is read from its fixed place and embedded).
Usage: python -I tools/models/kenney_convert.py tools/out/cc0 .
Writes assets/models/<kind>/<id>.glb and prints one line per model (triangles, size in metres, bytes).
The registry entries are assets/registry/models_kenney.json (by hand)."""
import json
import math
import os
import re
import struct
import sys

KITS = sys.argv[1]
ROOT = sys.argv[2]
FOOD = os.path.join(KITS, 'kenney_food-kit', 'files', 'Models', 'GLB format')
SURV = os.path.join(KITS, 'kenney_survival-kit', 'files', 'Models', 'GLB format')
FURN = os.path.join(KITS, 'kenney_furniturePack', 'files', 'Models')
MAX_IN = 4 << 20
ALLOWED_EXT = {'KHR_texture_transform', 'KHR_materials_unlit', 'KHR_materials_emissive_strength',
               'KHR_mesh_quantization', 'GODOT_single_root'}
UP_TO_FRONT = [math.sin(math.pi / 4), 0.0, 0.0, math.cos(math.pi / 4)]   # +90 deg about X: +Y -> +Z (lie down)
TURN = [0.0, 1.0, 0.0, 0.0]                                                 # 180 deg about Y

# (kit dir, file, out kind, out name, longest side in m, rotation or None)
GLBS = [
    (FOOD, 'pot', 'items', 'pot', 0.26, None),
    (FOOD, 'frying-pan', 'items', 'pan', 0.41, None),
    (FOOD, 'meat-raw', 'items', 'meat', 0.13, None),
    (FOOD, 'meat-cooked', 'items', 'meat_cooked', 0.13, None),
    (FOOD, 'can', 'items', 'can_food', 0.08, None),
    (FOOD, 'soda-can', 'items', 'can_drink', 0.122, None),
    (FOOD, 'soda-bottle', 'items', 'bottle_plastic', 0.19, None),
    (FOOD, 'apple', 'items', 'apple', 0.08, None),
    (FOOD, 'banana', 'items', 'banana', 0.19, None),
    (FOOD, 'orange', 'items', 'orange', 0.08, None),
    (FOOD, 'lemon', 'items', 'lemon', 0.075, None),
    (FOOD, 'pear', 'items', 'pear', 0.1, None),
    (FOOD, 'onion', 'items', 'onion', 0.08, None),
    (FOOD, 'tomato', 'items', 'tomato', 0.07, None),
    (FOOD, 'carrot', 'items', 'carrot', 0.19, UP_TO_FRONT),
    (FOOD, 'corn', 'items', 'corn', 0.2, None),
    (FOOD, 'mushroom', 'items', 'mushroom', 0.06, None),
    (FOOD, 'pumpkin', 'items', 'pumpkin', 0.3, None),
    (FOOD, 'eggplant', 'items', 'eggplant', 0.22, UP_TO_FRONT),
    (FOOD, 'broccoli', 'items', 'broccoli', 0.15, None),
    (FOOD, 'loaf', 'items', 'bread', 0.22, None),
    (FOOD, 'egg', 'items', 'egg_chicken', 0.055, None),
    (FOOD, 'chocolate', 'items', 'chocolate', 0.15, None),
    (FOOD, 'cookie', 'items', 'cookies', 0.07, None),
    (FOOD, 'plate', 'items', 'ceramic_plate', 0.26, None),
    (FOOD, 'bowl', 'items', 'ceramic_bowl', 0.15, None),
    (FOOD, 'mug', 'items', 'ceramic_mug', 0.12, None),
    (FOOD, 'utensil-fork', 'items', 'fork', 0.2, None),
    (FOOD, 'utensil-spoon', 'items', 'spoon', 0.19, None),
    (FOOD, 'utensil-knife', 'items', 'knife_butter', 0.21, None),
    (FOOD, 'rollingPin', 'items', 'rolling_pin', 0.46, None),
    (FOOD, 'whisk', 'items', 'whisk', 0.31, None),
    (FOOD, 'cooking-spatula', 'items', 'spatula', 0.24, None),
    (FOOD, 'cutting-board', 'items', 'cutting_board', 0.41, None),
    (SURV, 'bucket', 'items', 'bucket', 0.28, None),
    (SURV, 'tool-hammer', 'items', 'hammer', 0.3, UP_TO_FRONT),
    (SURV, 'tool-axe', 'items', 'hatchet', 0.38, UP_TO_FRONT),
    (SURV, 'tool-shovel', 'items', 'shovel', 1.2, UP_TO_FRONT),
    (SURV, 'tool-pickaxe', 'items', 'pickaxe', 0.9, UP_TO_FRONT),
    (SURV, 'tool-hoe', 'items', 'hoe', 1.4, UP_TO_FRONT),
    (SURV, 'campfire-pit', 'furniture', 'f_firering', 0.9, None),
]
# Furniture pack: OBJ in units of about 0.2 m, front -Z (turned to +Z here). The kitchen pieces are made
# 0.995 m wide (4.3 units) so a run of them closes up. Doors become door_N parts (hinged on their left, -X:
# the kit's handles are on the right), and surface_N planes where items lie (docs/MODELS.md); counters and
# sinks keep their door shut (CDDA's counter and sink hold nothing). Not converted: the crates and the bin
# (one piece, no lid), the dresser (the kit has none) and the workbench, which keep their placeholders.
# (file, out name, metres per unit up and front to back, metres per unit across, {OBJ group: part},
#  [(N, height, x0, z0, x1, z1, part or None)] in metres from the bottom centre, x before the widening)
KITCHEN_X = 0.995 / 4.3
OBJS = [
    ('kitchenStove', 'f_oven', 0.2, KITCHEN_X, {}, []),
    ('kitchenFridge', 'f_fridge', 0.2, KITCHEN_X, {'doorFridge': 'door_1', 'doorFreezer': 'door_2'}, [
        (1, 0.174, -0.36, -0.22, 0.36, 0.08, None),        # the fridge's floor
        (2, 0.401, -0.27, 0.10, 0.27, 0.20, 'door_1'),     # the door's bins
        (3, 0.741, -0.27, 0.10, 0.27, 0.20, 'door_1'),
        (4, 1.081, -0.27, 0.10, 0.27, 0.20, 'door_1'),
        (5, 1.434, -0.36, -0.22, 0.36, 0.12, None)]),      # the freezer's floor
    ('kitchenCabinet', 'f_cupboard', 0.2, KITCHEN_X, {'door 5': 'door_1'}, [
        (1, 0.17, -0.36, -0.33, 0.36, 0.33, None),
        (2, 0.475, -0.36, -0.33, 0.36, 0.33, None)]),
    ('kitchenCabinet', 'f_counter', 0.2, KITCHEN_X, {}, [(1, 0.84, -0.41, -0.37, 0.41, 0.43, None)]),
    ('kitchenSink', 'f_sink', 0.2, KITCHEN_X, {}, [(1, 0.64, -0.27, -0.18, 0.27, 0.24, None)]),
    ('bookcaseClosed', 'f_bookcase', 0.2, 0.2, {}, [
        (1, 0.26, -0.38, -0.23, 0.38, 0.19, None),
        (2, 0.74, -0.38, -0.23, 0.38, 0.19, None),
        (3, 1.22, -0.38, -0.23, 0.38, 0.19, None),
        (4, 1.7, -0.38, -0.23, 0.38, 0.23, None)]),
    ('chair', 'f_chair', 0.2, 0.2, {}, []),
    ('toilet', 'f_toilet', 0.18, 0.18, {}, []),
    ('washer', 'f_washer', 0.2, 0.2, {}, []),
    ('dryer', 'f_dryer', 0.2, 0.2, {}, []),
    ('cardboardBoxClosed', 'box_small', 0.075, 0.075, {}, []),
]


def read_capped(path):
    if os.path.islink(path) or not os.path.isfile(path):
        raise ValueError('not a plain file')
    if os.path.getsize(path) > MAX_IN:
        raise ValueError('too big')
    with open(path, 'rb') as f:
        return f.read(MAX_IN + 1)


def png_size(b):
    if len(b) < 33 or b[:8] != b'\x89PNG\r\n\x1a\n' or b[12:16] != b'IHDR':
        raise ValueError('not a PNG')
    return struct.unpack('>II', b[16:24])


def read_glb(b):
    magic, ver, total = struct.unpack_from('<III', b, 0)
    if magic != 0x46546C67 or ver != 2 or total != len(b):
        raise ValueError('not glb2')
    jl, jt = struct.unpack_from('<II', b, 12)
    if jt != 0x4E4F534A or 20 + jl > len(b):
        raise ValueError('bad json chunk')
    j = json.loads(b[20:20 + jl].decode('utf-8'))
    if not isinstance(j, dict):
        raise ValueError('json not an object')
    at = 20 + jl
    binc = b''
    if at + 8 <= len(b):
        bl, bt = struct.unpack_from('<II', b, at)
        if bt != 0x004E4942 or at + 8 + bl > len(b):
            raise ValueError('bad bin chunk')
        binc = b[at + 8:at + 8 + bl]
    return j, bytearray(binc)


def write_glb(path, j, binc):
    js = json.dumps(j, separators=(',', ':'), ensure_ascii=True).encode('ascii')
    js += b' ' * (-len(js) % 4)
    binc = bytes(binc) + b'\0' * (-len(binc) % 4)
    total = 12 + 8 + len(js) + 8 + len(binc)
    out = struct.pack('<III', 0x46546C67, 2, total) + struct.pack('<II', len(js), 0x4E4F534A) + js
    out += struct.pack('<II', len(binc), 0x004E4942) + binc
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(out)
    return len(out)


# --- small 4x4 matrix helpers (column vectors, row-major lists) ---
def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def quat_mat(q):
    x, y, z, w = q
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0],
            [0, 0, 0, 1]]


def node_mat(n):
    if 'matrix' in n:
        m = n['matrix']
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    t = n.get('translation', [0, 0, 0])
    r = quat_mat(n.get('rotation', [0, 0, 0, 1]))
    s = list(n.get('scale', [1, 1, 1])) + [1]
    m = [[r[i][j] * s[j] for j in range(4)] for i in range(4)]
    for i in range(3):
        m[i][3] = t[i]
    m[3] = [0, 0, 0, 1]
    return m


def apply(m, p):
    return [sum(m[i][k] * p[k] for k in range(3)) + m[i][3] for i in range(3)]


def bounds(points):
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    return lo, hi


def scene_corners(j):
    """Corners of every primitive's POSITION box, in scene space."""
    nodes = j.get('nodes', [])
    out = []

    def walk(i, parent, depth):
        if depth > 32:
            raise ValueError('too deep')
        n = nodes[i]
        m = mat_mul(parent, node_mat(n))
        if 'mesh' in n:
            for p in j['meshes'][n['mesh']]['primitives']:
                a = j['accessors'][p['attributes']['POSITION']]
                lo, hi = a['min'], a['max']
                for c in range(8):
                    out.append(apply(m, [(hi if c >> k & 1 else lo)[k] for k in range(3)]))
        for c in n.get('children', []):
            walk(c, m, depth + 1)

    ident = [[1 if i == k else 0 for k in range(4)] for i in range(4)]
    for r in j['scenes'][j.get('scene', 0)]['nodes']:
        walk(r, ident, 0)
    return out


def place(corners, rot, longest):
    """Root transform: turn by rot, scale so the longest side is `longest`, bottom centre at the origin."""
    rm = quat_mat(rot) if rot else None
    pts = [apply(rm, p) for p in corners] if rm else corners
    lo, hi = bounds(pts)
    size = [hi[i] - lo[i] for i in range(3)]
    s = longest / max(size)
    c = [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]
    return s, [-s * c[0], -s * c[1], -s * c[2]], [round(x * s, 4) for x in size]


def tris_of(j):
    t = 0
    for m in j.get('meshes', []):
        for p in m['primitives']:
            if p.get('mode', 4) != 4:
                raise ValueError('not triangles')
            a = j['accessors'][p['indices']] if 'indices' in p else j['accessors'][p['attributes']['POSITION']]
            t += a['count'] // 3
    return t


def convert_glb(kit, name, kind, out, longest, rot):
    b = read_capped(os.path.join(kit, name + '.glb'))
    j, binc = read_glb(b)
    for k in ('animations', 'skins', 'cameras'):
        if j.get(k):
            raise ValueError('has ' + k)
    if not set(j.get('extensionsUsed', [])) <= ALLOWED_EXT or not set(j.get('extensionsRequired', [])) <= ALLOWED_EXT:
        raise ValueError('extension')
    if len(j.get('buffers', [])) != 1 or 'uri' in j['buffers'][0]:
        raise ValueError('buffers')
    # The one image: the kit colormap, read from its fixed path and embedded.
    imgs = j.get('images', [])
    if len(imgs) > 1:
        raise ValueError('images')
    if imgs:
        png = read_capped(os.path.join(kit, 'Textures', 'colormap.png'))
        w, h = png_size(png)
        if w > 512 or h > 512:
            raise ValueError('texture too big')
        binc += b'\0' * (-len(binc) % 4)
        j.setdefault('bufferViews', []).append({'buffer': 0, 'byteOffset': len(binc), 'byteLength': len(png)})
        binc += png
        j['images'] = [{'bufferView': len(j['bufferViews']) - 1, 'mimeType': 'image/png', 'name': 'colormap'}]
    j['buffers'] = [{'byteLength': len(binc) + (-len(binc) % 4)}]
    s, t, size = place(scene_corners(j), rot, longest)
    for i, n in enumerate(j.get('nodes', [])):
        n['name'] = 'mesh_%d' % i
        n.pop('extras', None)
    for i, m in enumerate(j.get('meshes', [])):
        m['name'] = 'mesh_%d' % i
    for i, m in enumerate(j.get('materials', [])):
        m['name'] = 'colormap' if i == 0 else 'material_%d' % i
    scene = j['scenes'][j.get('scene', 0)]
    root = {'name': out, 'scale': [s, s, s], 'translation': t, 'children': list(scene['nodes'])}
    if rot:
        root['rotation'] = rot
    j['nodes'].append(root)
    j['scenes'] = [{'name': out, 'nodes': [len(j['nodes']) - 1]}]
    j['scene'] = 0
    j['asset'] = {'version': '2.0', 'generator': 'CDDA-3D Kenney conversion'}
    j.pop('extras', None)
    path = os.path.join(ROOT, 'assets', 'models', kind, out + '.glb')
    n = write_glb(path, j, binc)
    return tris_of(j), size, n


# --- OBJ (furniture pack: flat colours from the .mtl, no textures) ---
def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def safe_name(s, i):
    s = re.sub(r'[^A-Za-z0-9_]', '_', s)[:32]
    return s if s else 'material_%d' % i


def read_mtl(path):
    out = {}
    cur = None
    if not os.path.isfile(path):
        return out
    for line in read_capped(path).decode('utf-8', 'replace').splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == 'newmtl':
            cur = ' '.join(p[1:])[:64]
            out[cur] = [0.8, 0.8, 0.8]
        elif cur is not None and p[0] == 'Kd' and len(p) >= 4:
            out[cur] = [min(1.0, max(0.0, float(x))) for x in p[1:4]]
    return out


def convert_obj(name, out, unit, sx, parts, surfaces):
    text = read_capped(os.path.join(FURN, name + '.obj')).decode('utf-8', 'replace')
    mats = read_mtl(os.path.join(FURN, name + '.mtl'))
    vs = []
    faces = {}   # part ('' = the body) -> {material -> [vertex index triples]}
    order = []   # materials in first use
    part = ''
    cur = ''
    for line in text.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == 'v' and len(p) >= 4:
            vs.append([float(x) for x in p[1:4]])
            if len(vs) > 200000:
                raise ValueError('too many vertices')
        elif p[0] in ('g', 'o'):
            part = parts.get(' '.join(p[1:])[:64], '')
        elif p[0] == 'usemtl':
            cur = ' '.join(p[1:])[:64]
        elif p[0] == 'f' and len(p) >= 4:
            idx = []
            for v in p[1:]:
                k = int(v.split('/')[0])
                k = k - 1 if k > 0 else len(vs) + k
                if not 0 <= k < len(vs):
                    raise ValueError('bad index')
                idx.append(k)
            if cur not in order:
                order.append(cur)
            tris = faces.setdefault(part, {}).setdefault(cur, [])
            for i in range(1, len(idx) - 1):
                tris.append((idx[0], idx[i], idx[i + 1]))
    if sorted(p for p in faces if p) != sorted(parts.values()):
        raise ValueError('a part is missing')
    # Front -Z -> +Z (turn 180 about Y), metres, bottom centre at the origin.
    pts = [[-v[0] * sx, v[1] * unit, -v[2] * unit] for v in vs]
    lo, hi = bounds(pts)
    c = [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]
    pts = [[q[0] - c[0], q[1] - c[1], q[2] - c[2]] for q in pts]
    size = [round(hi[i] - lo[i], 4) for i in range(3)]
    binc = bytearray()
    j = {'asset': {'version': '2.0', 'generator': 'CDDA-3D Kenney conversion'}, 'scene': 0,
         'scenes': [{'name': out, 'nodes': [0]}], 'nodes': [{'name': out, 'children': []}],
         'meshes': [], 'materials': [], 'accessors': [], 'bufferViews': [], 'buffers': []}
    for mi, m in enumerate(order):
        kd = mats.get(m, [0.8, 0.8, 0.8])
        j['materials'].append({'name': safe_name(m, mi), 'pbrMetallicRoughness': {
            'baseColorFactor': [srgb_to_linear(x) for x in kd] + [1.0], 'metallicFactor': 0.0, 'roughnessFactor': 0.8}})

    def view(data, fmt, target):
        off = len(binc)
        for q in data:
            binc.extend(struct.pack(fmt, *q) if isinstance(q, (list, tuple)) else struct.pack(fmt, q))
        binc.extend(b'\0' * (-len(binc) % 4))
        j['bufferViews'].append({'buffer': 0, 'byteOffset': off, 'byteLength': len(data) * struct.calcsize(fmt),
                                 'target': target})
        return len(j['bufferViews']) - 1

    def primitive(pos, nor, material):
        if len(pos) >= 65536:
            raise ValueError('too many vertices for 16-bit indices')
        prim = {'attributes': {}, 'material': material, 'mode': 4}
        for key, data in (('POSITION', pos), ('NORMAL', nor)):
            acc = {'bufferView': view(data, '<fff', 34962), 'componentType': 5126, 'count': len(data), 'type': 'VEC3'}
            if key == 'POSITION':
                acc['min'], acc['max'] = bounds(data)
            j['accessors'].append(acc)
            prim['attributes'][key] = len(j['accessors']) - 1
        j['accessors'].append({'bufferView': view(range(len(pos)), '<H', 34963), 'componentType': 5123,
                               'count': len(pos), 'type': 'SCALAR'})
        prim['indices'] = len(j['accessors']) - 1
        return prim

    def mesh(by_material, shift):
        """A mesh of the faces (flat shaded), moved by -shift; [mesh index, triangles]."""
        prims = []
        n = 0
        for mi, m in enumerate(order):
            pos = []
            nor = []
            for a, b2, c2 in by_material.get(m, []):
                pa, pb, pc = ([pts[i][k] - shift[k] for k in range(3)] for i in (a, b2, c2))
                u = [pb[i] - pa[i] for i in range(3)]
                w = [pc[i] - pa[i] for i in range(3)]
                nv = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]]
                ln = math.sqrt(sum(x * x for x in nv))
                if ln < 1e-12:
                    continue
                nv = [x / ln for x in nv]
                pos += [pa, pb, pc]   # the turn keeps handedness, so the winding stays counter-clockwise
                nor += [nv, nv, nv]
            if pos:
                prims.append(primitive(pos, nor, mi))
                n += len(pos) // 3
        j['meshes'].append({'name': 'mesh_%d' % len(j['meshes']), 'primitives': prims})
        return len(j['meshes']) - 1, n

    def add_node(node, parent):
        j['nodes'].append(node)
        j['nodes'][parent].setdefault('children', []).append(len(j['nodes']) - 1)
        return len(j['nodes']) - 1

    body, tris = mesh(faces.get('', {}), [0, 0, 0])
    add_node({'name': 'body', 'mesh': body}, 0)
    movers = {}   # part -> [node index, pivot]
    for pname in sorted(p for p in faces if p):
        used = {i for t in faces[pname].values() for f in t for i in f}
        plo, phi = bounds([pts[i] for i in used])
        if pname.startswith('door_'):   # on the hinge line: its left front edge
            pivot = [plo[0], plo[1], phi[2]]
        else:
            pivot = [(plo[0] + phi[0]) / 2, plo[1], (plo[2] + phi[2]) / 2]
        leaf, n = mesh(faces[pname], pivot)
        tris += n
        at = add_node({'name': pname, 'translation': pivot}, 0)
        add_node({'name': 'leaf_' + pname.split('_')[1], 'mesh': leaf}, at)
        movers[pname] = [at, pivot]
    k = sx / unit
    for n, y, x0, z0, x1, z1, owner in surfaces:
        parent, shift = movers[owner] if owner else [0, [0, 0, 0]]
        quad = [[x * k - shift[0], y - shift[1], z - shift[2]] for x, z in ((x0, z0), (x0, z1), (x1, z1), (x1, z0))]
        pos = [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]]
        j['meshes'].append({'name': 'mesh_%d' % len(j['meshes']), 'primitives': [primitive(pos, [[0, 1, 0]] * 6, 0)]})
        add_node({'name': 'surface_%d' % n, 'mesh': len(j['meshes']) - 1}, parent)
    j['buffers'] = [{'byteLength': len(binc)}]
    path = os.path.join(ROOT, 'assets', 'models', 'furniture' if out.startswith('f_') else 'items', out + '.glb')
    size_bytes = write_glb(path, j, binc)
    return tris, size, size_bytes, len(j['materials'])


if __name__ == '__main__':
    for kit, name, kind, out, longest, rot in GLBS:
        try:
            t, size, n = convert_glb(kit, name, kind, out, longest, rot)
            print('%-16s %-16s tris %5d size %s bytes %d' % (out, name, t, size, n))
        except Exception as e:
            print('%-16s %-16s ERROR %s %s' % (out, name, type(e).__name__, str(e)[:80]))
    for name, out, unit, sx, parts, surfaces in OBJS:
        try:
            t, size, n, mats = convert_obj(name, out, unit, sx, parts, surfaces)
            print('%-16s %-16s tris %5d size %s bytes %d materials %d' % (out, name, t, size, n, mats))
        except Exception as e:
            print('%-16s %-16s ERROR %s %s' % (out, name, type(e).__name__, str(e)[:80]))
