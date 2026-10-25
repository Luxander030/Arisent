#!/usr/bin/env python3
"""Builds a small GLB holding one rig's skeleton plus a few named animations from another
GLB of the same rig (animations retargeted by node name). Used to keep only the ladder
clips from the afk-rig animation library (CC0) instead of the whole 5 MB file.

  python3 tools/rig/extract_clips.py <rig.glb> <animations.glb> <out.glb> "Clip A" "Clip B" ...
"""
import json, struct, sys


COMPONENTS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}
COMPONENT_BYTES = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}


def read_glb(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'glTF', path
    off, js, binc = 12, None, b''
    while off < len(b):
        n, kind = struct.unpack('<I4s', b[off:off + 8])
        chunk = b[off + 8:off + 8 + n]
        if kind == b'JSON':
            js = json.loads(chunk)
        elif kind == b'BIN\x00':
            binc = chunk
        off += 8 + n
    return js, binc


def write_glb(path, js, binc):
    jb = json.dumps(js, separators=(',', ':')).encode()
    jb += b' ' * (-len(jb) % 4)
    binc += b'\x00' * (-len(binc) % 4)
    total = 12 + 8 + len(jb) + 8 + len(binc)
    with open(path, 'wb') as f:
        f.write(struct.pack('<4sII', b'glTF', 2, total))
        f.write(struct.pack('<I4s', len(jb), b'JSON') + jb)
        f.write(struct.pack('<I4s', len(binc), b'BIN\x00') + binc)


def main():
    rig_path, anim_path, out_path, *clips = sys.argv[1:]
    rig, rig_bin = read_glb(rig_path)
    src, src_bin = read_glb(anim_path)
    out_bin = bytearray(rig_bin)
    out_bin += b'\x00' * (-len(out_bin) % 4)
    rig_node = {n.get('name'): i for i, n in enumerate(rig['nodes'])}
    rig.setdefault('accessors', [])
    rig.setdefault('bufferViews', [])
    copied = {}

    def copy_accessor(ai):
        if ai in copied:
            return copied[ai]
        acc = dict(src['accessors'][ai])
        bv = src['bufferViews'][acc['bufferView']]
        assert 'byteStride' not in bv, 'interleaved data is not supported'
        size = acc['count'] * COMPONENTS[acc['type']] * COMPONENT_BYTES[acc['componentType']]
        start = bv.get('byteOffset', 0) + acc.get('byteOffset', 0)
        data = src_bin[start:start + size]  # only this accessor's bytes (views are shared by many)
        while len(out_bin) % 4:
            out_bin.append(0)
        bv = {'buffer': 0, 'byteOffset': len(out_bin), 'byteLength': size}
        acc['byteOffset'] = 0
        out_bin.extend(data)
        rig['bufferViews'].append(bv)
        acc['bufferView'] = len(rig['bufferViews']) - 1
        rig['accessors'].append(acc)
        copied[ai] = len(rig['accessors']) - 1
        return copied[ai]

    anims = []
    for a in src.get('animations', []):
        if a['name'] not in clips:
            continue
        samplers, channels = [], []
        for ch in a['channels']:
            name = src['nodes'][ch['target']['node']].get('name')
            if name not in rig_node:
                continue  # a node the rig doesn't have
            s = a['samplers'][ch['sampler']]
            samplers.append({'input': copy_accessor(s['input']), 'output': copy_accessor(s['output']),
                             'interpolation': s.get('interpolation', 'LINEAR')})
            channels.append({'sampler': len(samplers) - 1, 'target': {'node': rig_node[name], 'path': ch['target']['path']}})
        anims.append({'name': a['name'], 'samplers': samplers, 'channels': channels})
    missing = set(clips) - {a['name'] for a in anims}
    assert not missing, f'not found: {missing}'
    rig['animations'] = anims
    rig['buffers'] = [{'byteLength': len(out_bin)}]
    write_glb(out_path, rig, bytes(out_bin))
    print(f'{out_path}: {len(anims)} clips, {len(out_bin)} bytes of data')


main()
