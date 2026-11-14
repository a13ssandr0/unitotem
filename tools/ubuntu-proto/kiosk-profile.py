#!/usr/bin/python3
"""Graphics profile of the kiosk pages through DevTools (loopback 9223): rAF cadence per window, running animations, layer and
paint counters, browser trace (compositor, GPU, raster) and the CPU of the processes, for DURATION seconds. Output: JSON on stdout."""
import asyncio, json, os, subprocess, sys, time, urllib.request, collections
import websockets

DURATION = int(os.environ.get('DURATION', '10'))
BASE = 'http://127.0.0.1:9223'

RAF = """(async (secs) => {
  const t = []; const t0 = performance.now();
  await new Promise(res => { function f(ts) { t.push(ts); if (ts - t0 < secs * 1000) requestAnimationFrame(f); else res(); } requestAnimationFrame(f); });
  const d = t.slice(1).map((x, i) => x - t[i]).sort((a, b) => a - b);
  const q = p => d.length ? +d[Math.min(d.length - 1, Math.floor(d.length * p))].toFixed(2) : null;
  return {frames: t.length, fps: +(t.length / secs).toFixed(1), p50: q(.5), p95: q(.95), p99: q(.99), max: d.length ? +d[d.length - 1].toFixed(1) : null,
          over20: d.filter(x => x > 20).length, over34: d.filter(x => x > 34).length, over50: d.filter(x => x > 50).length};
})(%d)"""
INFO = """(() => ({href: location.href, size: innerWidth + 'x' + innerHeight, dpr: devicePixelRatio, text: document.body.innerText.trim().slice(0, 160),
  animations: document.getAnimations().map(a => ({target: (a.effect.target && (a.effect.target.id || a.effect.target.className || a.effect.target.tagName)) + '' + (a.effect.pseudoElement || ''),
    name: a.animationName || a.transitionProperty || '', props: [...new Set(a.effect.getKeyframes().flatMap(k => Object.keys(k)).filter(k => !['offset', 'easing', 'composite', 'computedOffset'].includes(k)))],
    duration: a.effect.getTiming().duration, easing: a.effect.getTiming().easing, state: a.playState})),
  elements: document.getElementsByTagName('*').length}))()"""

def get(path):
    return json.load(urllib.request.urlopen(BASE + path, timeout=5))

class Cdp:
    def __init__(self, url):
        self.url, self.n, self.ev, self.pending = url, 0, [], {}
    async def __aenter__(self):
        self.ws = await websockets.connect(self.url, max_size=None, ping_interval=None)
        self.task = asyncio.create_task(self._rd()); return self
    async def __aexit__(self, *a):
        self.task.cancel(); await self.ws.close()
    async def _rd(self):
        async for m in self.ws:
            d = json.loads(m)
            if 'id' in d and d['id'] in self.pending: self.pending.pop(d['id']).set_result(d)
            else: self.ev.append(d)
    async def call(self, method, **params):
        self.n += 1; f = asyncio.get_event_loop().create_future(); self.pending[self.n] = f
        await self.ws.send(json.dumps({'id': self.n, 'method': method, 'params': params}))
        return (await asyncio.wait_for(f, 60)).get('result', {})

def cpu_sample(dur):
    """Per-process CPU% (user+sys) over dur seconds for the processes of the display path."""
    def snap():
        out = {}
        for p in os.listdir('/proc'):
            if not p.isdigit(): continue
            try:
                s = open(f'/proc/{p}/stat').read(); c = s[s.index('(') + 1:s.rindex(')')]; f = s[s.rindex(')') + 2:].split()
                a = open(f'/proc/{p}/cmdline').read().replace('\0', ' ')[:140]
                out[int(p)] = (c, a, int(f[11]) + int(f[12]))
            except Exception: pass
        return out
    a = snap(); time.sleep(dur); b = snap(); hz = os.sysconf('SC_CLK_TCK')
    rows = []
    for p, (c, cmd, t1) in b.items():
        t0 = a.get(p, (c, cmd, 0))[2]
        pct = (t1 - t0) / hz / dur * 100
        if pct >= 1: rows.append({'pid': p, 'comm': c, 'cpu_pct': round(pct, 1), 'cmd': cmd})
    return sorted(rows, key=lambda r: -r['cpu_pct'])[:12]

async def main():
    res = {'duration_s': DURATION}
    pages = [t for t in get('/json') if t.get('type') == 'page']
    browser = get('/json/version')['webSocketDebuggerUrl']
    res['targets'] = [t['url'] for t in pages]
    loop = asyncio.get_event_loop()
    cpu_f = loop.run_in_executor(None, cpu_sample, DURATION)
    def gpu():
        try: return subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu,utilization.memory,clocks.gr,clocks.mem,power.draw,temperature.gpu', '--format=csv,noheader', '-l', '1', '-c', str(DURATION)], capture_output=True, text=True).stdout.split('\n')
        except FileNotFoundError: return ['nvidia-smi not installed']
    gpu_f = loop.run_in_executor(None, gpu)
    async def page(t):
        async with Cdp(t['webSocketDebuggerUrl']) as c:
            await c.call('Performance.enable')
            m0 = {x['name']: x['value'] for x in (await c.call('Performance.getMetrics'))['metrics']}
            info = (await c.call('Runtime.evaluate', expression=INFO, returnByValue=True))['result'].get('value')
            raf = (await c.call('Runtime.evaluate', expression=RAF % DURATION, awaitPromise=True, returnByValue=True))['result'].get('value')
            m1 = {x['name']: x['value'] for x in (await c.call('Performance.getMetrics'))['metrics']}
            keys = ['LayoutCount', 'RecalcStyleCount', 'LayoutDuration', 'RecalcStyleDuration', 'ScriptDuration', 'TaskDuration', 'JSHeapUsedSize', 'Nodes']
            return {'title': t['title'], 'info': info, 'raf': raf, 'delta': {k: round(m1.get(k, 0) - m0.get(k, 0), 4) for k in keys}}
    async def trace():
        async with Cdp(browser) as c:
            await c.call('Tracing.start', traceConfig={'recordMode': 'recordContinuously', 'includedCategories': ['-*', 'cc', 'viz', 'gpu', 'toplevel', 'benchmark', 'latency', 'disabled-by-default-cc.debug.display_items'][:7]}, transferMode='ReportEvents')
            await asyncio.sleep(DURATION)
            await c.call('Tracing.end')
            for _ in range(120):
                if any(e.get('method') == 'Tracing.tracingComplete' for e in c.ev): break
                await asyncio.sleep(0.5)
            ev = [x for e in c.ev if e.get('method') == 'Tracing.dataCollected' for x in e['params']['value']]
            names = collections.defaultdict(lambda: [0, 0.0])
            for x in ev:
                if x.get('ph') == 'X': n = names[x['name']]; n[0] += 1; n[1] += x.get('dur', 0) / 1000
                elif x.get('ph') in ('b', 'I', 'n'): names[x['name']][0] += 1
            top = sorted(names.items(), key=lambda kv: -kv[1][0])[:40]
            return {'events': len(ev), 'top_by_count': [{'name': k, 'count': v[0], 'total_ms': round(v[1], 1)} for k, v in top]}
    out = await asyncio.gather(trace(), *[page(t) for t in pages], return_exceptions=True)
    res['trace'] = out[0] if not isinstance(out[0], Exception) else repr(out[0])
    res['pages'] = [o if not isinstance(o, Exception) else repr(o) for o in out[1:]]
    res['cpu'] = await cpu_f
    res['gpu'] = [l for l in await gpu_f if l]
    try: res['psi_cpu'] = open('/proc/pressure/cpu').read().strip().split('\n')[0]
    except OSError: pass
    print(json.dumps(res, indent=1))
asyncio.run(main())
