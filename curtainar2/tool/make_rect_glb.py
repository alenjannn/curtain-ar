"""Generate a minimal self-contained GLB: a 1.0 x 2.0 m quad, semi-transparent blue.

ar_flutter_plugin_updated has no primitive-geometry NodeType (only GLTF2/GLB),
so the "flat blue rectangle" has to arrive as a model file.

Authored in the XY plane (normal = +Z), centred on the origin, in METRES.
"""

import json
import struct
import sys

W, H = 1.0, 2.0
hw, hh = W / 2.0, H / 2.0

positions = [
    (-hw, -hh, 0.0),
    ( hw, -hh, 0.0),
    ( hw,  hh, 0.0),
    (-hw,  hh, 0.0),
]
normals = [(0.0, 0.0, 1.0)] * 4
indices = [0, 1, 2, 0, 2, 3]  # CCW seen from +Z

buf = bytearray()
pos_off = len(buf)
for p in positions:
    buf += struct.pack("<3f", *p)
nrm_off = len(buf)
for n in normals:
    buf += struct.pack("<3f", *n)
idx_off = len(buf)
for i in indices:
    buf += struct.pack("<H", i)
while len(buf) % 4:
    buf += b"\x00"

gltf = {
    "asset": {"version": "2.0", "generator": "simply-curtains phase2 placement rect"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"mesh": 0, "name": "placement_rect"}],
    "meshes": [{
        "name": "placement_rect",
        "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1},
            "indices": 2,
            "material": 0,
            "mode": 4,
        }],
    }],
    "materials": [{
        "name": "placement_blue",
        "pbrMetallicRoughness": {
            # rgba(0, 100, 255, 0.6)
            "baseColorFactor": [0.0, 100 / 255, 1.0, 0.6],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.9,
        },
        # Keeps the rectangle readable in a dim room without relying on scene lights.
        "emissiveFactor": [0.0, 0.12, 0.30],
        "alphaMode": "BLEND",
        "doubleSided": True,
    }],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
         "min": [-hw, -hh, 0.0], "max": [hw, hh, 0.0]},
        {"bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5123, "count": 6, "type": "SCALAR"},
    ],
    "bufferViews": [
        {"buffer": 0, "byteOffset": pos_off, "byteLength": nrm_off - pos_off, "target": 34962},
        {"buffer": 0, "byteOffset": nrm_off, "byteLength": idx_off - nrm_off, "target": 34962},
        {"buffer": 0, "byteOffset": idx_off, "byteLength": 12, "target": 34963},
    ],
    "buffers": [{"byteLength": len(buf)}],
}

json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
while len(json_bytes) % 4:
    json_bytes += b" "

glb = bytearray()
glb += struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(json_bytes) + 8 + len(buf))
glb += struct.pack("<II", len(json_bytes), 0x4E4F534A) + json_bytes
glb += struct.pack("<II", len(buf), 0x004E4942) + bytes(buf)

with open(sys.argv[1], "wb") as f:
    f.write(glb)
print(f"wrote {sys.argv[1]}: {len(glb)} bytes")
