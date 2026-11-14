#!/usr/bin/env python3
"""Runs commands in the web terminal of a UniTotem test VM: ut-term.py HOST USER PASSWORD 'cmd' ..."""
import asyncio, json, ssl, sys, urllib.request, urllib.parse, http.cookiejar, websockets

host, user, pw, *cmds = sys.argv[1:]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=ctx))
op.open(urllib.request.Request(f'https://{host}/auth/token', urllib.parse.urlencode({'username': user, 'password': pw, 'src': '/'}).encode()))
cookie = '; '.join(f'{c.name}={c.value}' for c in jar)
tok = json.load(op.open(urllib.request.Request(f'https://{host}/terminal/token', b'', method='POST')))
token = tok.get('token') if isinstance(tok, dict) else tok

async def main():
    async with websockets.connect(f'wss://{host}/terminal', ssl=ctx, additional_headers={'Cookie': cookie, 'Origin': f'https://{host}'}) as ws:
        await ws.send(json.dumps({'token': token}))
        out = b''
        async def rd(t):
            nonlocal out
            end = asyncio.get_event_loop().time() + t
            while asyncio.get_event_loop().time() < end:
                try:
                    m = await asyncio.wait_for(ws.recv(), 0.5)
                    if isinstance(m, bytes): out += m
                except asyncio.TimeoutError:
                    pass
                except websockets.ConnectionClosed as e:
                    out += ('\n[closed %s %s]\n' % (e.rcvd.code if e.rcvd else '', e.rcvd.reason if e.rcvd else '')).encode(); return
        await rd(2)
        for c in cmds:
            try: await ws.send((c + '\n').encode())
            except Exception: break
            await rd(4)
        try: await ws.send(b'exit\n'); await rd(1)
        except Exception: pass
    sys.stdout.write(out.decode('utf-8', 'replace'))
asyncio.run(main())
