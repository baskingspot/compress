import sys, statistics, collections
d = sys.argv[1]
arms = ['base', 'new', 'libdeflate', 'wuffs']
v = {a: collections.defaultdict(list) for a in arms}
for a in arms:
    for line in open(f'{d}/{a}.txt'):
        f = line.split()
        v[a][f[0].split('/', 1)[1]].append(float(f[4]))
print('| file | base | new | speedup | libdeflate | vs libdeflate | Wuffs | vs Wuffs |')
print('| --- | --- | --- | --- | --- | --- | --- | --- |')
for k in sorted(v['base']):
    m = {a: statistics.median(v[a][k]) for a in arms}
    print(f"| {k} | {m['base']:.0f} | {m['new']:.0f} | {m['new']/m['base']:.2f}× | {m['libdeflate']:.0f} | {m['new']/m['libdeflate']:.2f} | {m['wuffs']:.0f} | {m['new']/m['wuffs']:.2f} |")
