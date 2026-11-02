import sys, struct, zlib
for path in sys.argv[2:]:
    d = open(path,'rb').read()
    i = 8; out = b''
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i+8])
        if t == b'IDAT': out += d[i+8:i+8+n]
        i += 12 + n
    name = path.split('/')[-1].replace('.png','')
    open(sys.argv[1] + '/' + name + '.z','wb').write(out)
    print(name, len(out), len(zlib.decompress(out)))
