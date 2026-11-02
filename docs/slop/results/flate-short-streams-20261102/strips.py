# strips.py OUT FILE...: each TIFF's strips (zlib streams) as OUT/<name>.zs,
# records of a u32 little-endian length and the stream.
import sys, struct, zlib
for path in sys.argv[2:]:
    d = open(path, 'rb').read()
    e = '<' if d[:2] == b'II' else '>'
    off = struct.unpack(e + 'I', d[4:8])[0]
    n = struct.unpack(e + 'H', d[off:off + 2])[0]
    tags = {}
    for i in range(n):
        t, ty, c, v = struct.unpack(e + 'HHII', d[off + 2 + 12 * i:off + 14 + 12 * i])
        size = {3: 2, 4: 4}[ty] if ty in (3, 4) else 4
        if c * size <= 4:
            vals = [struct.unpack(e + ('H' if ty == 3 else 'I'), d[off + 10 + 12 * i + k * size:][:size])[0] for k in range(c)]
        else:
            vals = [struct.unpack(e + ('H' if ty == 3 else 'I'), d[v + k * size:][:size])[0] for k in range(c)]
        tags[t] = vals
    out = b''
    total = 0
    for o, c in zip(tags[273], tags[279]):
        s = d[o:o + c]
        total += len(zlib.decompress(s))
        out += struct.pack('<I', len(s)) + s
    name = path.split('/')[-1].replace('.tif', '')
    open(sys.argv[1] + '/' + name + '.zs', 'wb').write(out)
    print(name, len(tags[273]), len(out), total)
