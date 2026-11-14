#!/usr/bin/python3
"""A/B of the first-boot welcome page: baseline, animation removed, gradient moved to a compositor-only transform.
For every phase: rAF cadence inside the page, CPU% of the display path processes, raster and pipeline counts of the browser trace."""
import asyncio, json, os, sys, time, urllib.request, collections
sys.path.insert(0, '/var/tmp')
import importlib.util
spec = importlib.util.spec_from_file_location('wp', '/var/tmp/prof.py')
src = open('/var/tmp/prof.py').read().replace('asyncio.run(main())', '')
wp = type(sys)('wp'); exec(compile(src, 'prof.py', 'exec'), wp.__dict__)
Cdp, get, cpu_sample, RAF = wp.Cdp, wp.get, wp.cpu_sample, wp.RAF
D = 10

CSS = {
 'baseline': '',
 'no-animation': 'body{animation:none !important}',
 'transform-gradient': ("body{animation:none !important;background:#23a6d5 !important}"
   "body::before{content:'';position:fixed;left:-150vw;top:-150vh;width:400vw;height:400vh;z-index:-1;"
   "background:linear-gradient(-45deg,#ee7752,#e73c7e,#23a6d5,#23d5ab);will-change:transform;"
   "animation:drift 5s ease infinite alternate}@keyframes drift{from{transform:translate(0,0)}to{transform:translate(-100vw,0)}}"),
}

async def phase(name, css, frames):
    for f in frames:
        async with Cdp(f['webSocketDebuggerUrl']) as c:
            js = "(()=>{let s=document.getElementById('exp');if(s)s.remove();" + ("s=document.createElement('style');s.id='exp';s.textContent=%s;document.head.appendChild(s);" % json.dumps(css) if css else '') + "return 1})()"
            await c.call('Runtime.evaluate', expression=js, returnByValue=True)
    await asyncio.sleep(2)
    loop = asyncio.get_event_loop()
    cpu_f = loop.run_in_executor(None, cpu_sample, D)
    br = get('/json/version')['webSocketDebuggerUrl']
    async def trace():
        async with Cdp(br) as c:
            await c.call('Tracing.start', traceConfig={'recordMode': 'recordContinuously', 'includedCategories': ['-*', 'cc', 'viz', 'gpu', 'toplevel']}, transferMode='ReportEvents')
            await asyncio.sleep(D); await c.call('Tracing.end')
            for _ in range(120):
                if any(e.get('method') == 'Tracing.tracingComplete' for e in c.ev): break
                await asyncio.sleep(0.5)
            ev = [x for e in c.ev if e.get('method') == 'Tracing.dataCollected' for x in e['params']['value']]
            cnt = collections.Counter(x['name'] for x in ev if x.get('ph') in ('X', 'b', 'I'))
            dur = collections.defaultdict(float)
            for x in ev:
                if x.get('ph') == 'X': dur[x['name']] += x.get('dur', 0) / 1000
            keys = ['RasterDecoderImpl::DoRasterCHROMIUM', 'Graphics.Pipeline', 'LayerTreeHostImpl::NotifyTileStateChanged', 'SkiaOutputSurfaceImplOnGpu::SwapBuffers', 'Display::DrawAndSwap']
            return {k: {'n': cnt.get(k, 0), 'ms': round(dur.get(k, 0), 1)} for k in keys}
    async def raf(f):
        async with Cdp(f['webSocketDebuggerUrl']) as c:
            return (await c.call('Runtime.evaluate', expression=RAF % D, awaitPromise=True, returnByValue=True))['result'].get('value')
    out = await asyncio.gather(trace(), *[raf(f) for f in frames])
    cpu = await cpu_f
    sel = [r for r in cpu if r['comm'] in ('labwc', 'subprocess')]
    return {'phase': name, 'trace': out[0], 'raf': out[1:], 'cpu': [{'c': r['comm'], 'cmd': ('gpu' if 'gpu-process' in r['cmd'] else 'renderer' if 'renderer' in r['cmd'] else r['cmd'][:30]), 'pct': r['cpu_pct']} for r in sel], 'cpu_total': round(sum(r['cpu_pct'] for r in cpu), 1)}

async def main():
    frames = [t for t in get('/json') if 'unitotem-first-boot' in t['url']]
    res = {'frames': [(t['type'], t['url']) for t in frames], 'all_targets': [(t['type'], t['url'][:90]) for t in get('/json')], 'phases': []}
    if frames:
        for name, css in CSS.items():
            res['phases'].append(await phase(name, css, frames))
        for name, css in [('baseline-again', '')]:
            res['phases'].append(await phase(name, css, frames))
    print(json.dumps(res, indent=1))
asyncio.run(main())
