import sys, re
name = sys.argv[1]; import os; os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'work', 'update-load'))
fe = open(f'{name}.fetch.log').read()
t0 = float(re.search(r'fetch start ([\d.]+)', fe).group(1)); t1 = float(re.search(r'fetch end ([\d.]+)', fe).group(1))
rows = []
for l in open(f'{name}.pi.log'):
    f = l.split()
    if len(f) < 14: continue
    try: v = [float(x) for x in f]
    except ValueError: continue
    rows.append(v)
probes = []
for l in open(f'{name}.probe.log'):
    m = re.match(r'([\d.]+) web=(\S+) ssh=(\S+)', l)
    if not m: continue
    def num(s):
        try: return float(s)
        except ValueError: return 99.0   # failure or timeout counts as 99 s
    probes.append((float(m.group(1)), num(m.group(2).replace('fail','')) if m.group(2)!='15.00' else 15.0, num(m.group(3))))
def phase(t):
    return 'before' if t < t0 else ('fetch' if t <= t1 else 'after')
print(f'fetch lasted {t1-t0:.0f} s')
# window table
W = 15
start = rows[0][0]
print('t(s) phase   load  cpu%  iowait% wr_MB/s inflight dirtyMB  web_max  ssh_max  rd_ms_max')
i = 1
for k in range(0, int((rows[-1][0]-start)//W)+1):
    a = [r for r in rows if start+k*W <= r[0] < start+(k+1)*W]
    if len(a) < 2: continue
    d = lambda j: a[-1][j]-a[0][j]
    tot = d(2)+d(3)+d(4)+d(5)   # busy+idle+iowait+softirq jiffies
    busy = (d(2)+d(5))/tot*100 if tot else 0
    iow = d(4)/tot*100 if tot else 0
    wr = d(9)*512/1e6/(a[-1][0]-a[0][0])
    pr = [p for p in probes if start+k*W <= p[0] < start+(k+1)*W]
    wm = max([p[1] for p in pr], default=0); sm = max([p[2] for p in pr], default=0)
    rd = max((r[14] for r in a if len(r) > 14), default=-1)
    print(f'{k*W:4d} {phase(a[0][0]):6} {max(r[1] for r in a):6.2f} {busy:5.0f} {iow:7.0f} {wr:8.1f} {max(r[11] for r in a):8.0f} {max(r[12] for r in a)/1024:7.0f} {wm:8.2f} {sm:8.2f} {rd:8.0f}')
fp = [p for p in probes if phase(p[0]) == 'fetch']
bp = [p for p in probes if phase(p[0]) == 'before']
import statistics as st
for label, ps in (('before', bp), ('fetch', fp)):
    if ps:
        w = sorted(p[1] for p in ps); s = sorted(p[2] for p in ps)
        print(f'{label}: probes {len(ps)}  web median {st.median(w):.2f} p90 {w[int(len(w)*.9)]:.2f} max {w[-1]:.2f} fails {sum(1 for x in w if x>=15)}   ssh median {st.median(s):.2f} max {s[-1]:.2f} fails {sum(1 for x in s if x>=10)}')
