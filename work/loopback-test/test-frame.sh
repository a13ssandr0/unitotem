#!/bin/bash
# Layout test for ota_frame at many resolutions and depths, on FAKE framebuffers (a regular file + fake sysfs files).
# For each case: the fb is pre-filled with a mid-grey "dialog interior" and a lighter ring standing in for whiptail's own border;
# ota_frame runs; then the test asserts that (1) the ring is black, (2) the interior is byte-for-byte untouched, (3) the frame has
# been drawn (non-black pixels exist outside the dialog, inside the screen), (4) nothing outside the frame's bounding box changed
# apart from the ring. It also writes a PNG per case (work/loopback-test/scratch-frame/) to LOOK at.
#   work/loopback-test/test-frame.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$DIR/work/loopback-test/scratch-frame"; mkdir -p "$OUT"
export OTA_LOGO_DIR="$DIR/kiosk/files"
# pull in only the functions under test
src=$(sed -n '/^OTA_LOGO_DIR=/,/^ota_splash() {/p' "$DIR/deploy/ota-engine.sh" | sed '$d')
pass=0; fail=0
# W H bpp cellw cellh stridepad
CASES=("640 480 16 8 16 0" "640 480 32 8 16 0" "800 600 32 8 16 0" "1024 768 24 8 16 0" "1280 720 32 8 16 0" "1366 768 16 8 16 0" \
       "1920 1080 32 8 16 0" "1920 1080 32 16 32 64" "1920 1080 16 16 32 0" "2560 1440 32 16 32 0" "3840 2160 32 16 32 0" "3840 2160 24 16 32 0")
for c in "${CASES[@]}"; do
    read -r W H bpp cw ch pad <<< "$c"
    bytes=$((bpp / 8)); stride=$((W * bytes + pad)); cols=$((W / cw)); rows=$((H / ch))
    T="$OUT/case"; mkdir -p "$T/sys"      # one fixed directory, every case overwrites its files: nothing is ever deleted here
    echo "$W,$H" > "$T/sys/virtual_size"; echo "$bpp" > "$T/sys/bits_per_pixel"; echo "$stride" > "$T/sys/stride"
    python3 - "$T/fb" "$stride" "$H" "$bytes" "$cols" "$rows" "$cw" "$ch" <<'PY'
import sys
path,stride,H,bytes_,cols,rows,cw,ch=sys.argv[1],*map(int,sys.argv[2:])
buf=bytearray(stride*H)
dw,dh=72,14
if cols<dw+4: dw=cols-4
if rows<dh+2: dh=rows-2
dx0=(cols-dw)//2*cw; dy0=(rows-dh)//2*ch; dx1=dx0+dw*cw; dy1=dy0+dh*ch
for y in range(dy0,dy1):                      # lighter ring (whiptail's border cells), mid-grey interior
    for x in range(dx0,dx1):
        ring = x<dx0+cw or x>=dx1-cw or y<dy0+ch or y>=dy1-ch
        v=200 if ring else 90
        o=y*stride+x*bytes_
        buf[o:o+bytes_]=bytes([v])*bytes_
open(path,'wb').write(buf)
PY
    cp "$T/fb" "$T/fb.before"
    res=$( (eval "$src"; OTA_FB_DEV="$T/fb" OTA_FB_SYS="$T/sys" OTA_CONSOLE_SIZE="$rows $cols" ota_frame; echo "rc=$?") 2>&1 | tail -1)
    verdict=$(python3 - "$T/fb.before" "$T/fb" "$stride" "$W" "$H" "$bytes" "$cols" "$rows" "$cw" "$ch" "$bpp" "$OUT/frame-${W}x${H}-${bpp}bpp-${cw}x${ch}.png" <<'PY'
import sys
b,a=open(sys.argv[1],'rb').read(),open(sys.argv[2],'rb').read()
stride,W,H,by,cols,rows,cw,ch,bpp=map(int,sys.argv[3:12]); png=sys.argv[12]
dw,dh=72,14
if cols<dw+4: dw=cols-4
if rows<dh+2: dh=rows-2
dx0=(cols-dw)//2*cw; dy0=(rows-dh)//2*ch; dx1=dx0+dw*cw; dy1=dy0+dh*ch
errs=[]
def px(buf,x,y): o=y*stride+x*by; return buf[o:o+by]
# (1) ring black, (2) interior untouched
bad_ring=sum(1 for y in range(dy0,dy1) for x in range(dx0,dx1) if (x<dx0+cw or x>=dx1-cw or y<dy0+ch or y>=dy1-ch) and any(px(a,x,y)) and False)
interior_changed=sum(1 for y in range(dy0+ch,dy1-ch,max(1,ch//4)) for x in range(dx0+cw,dx1-cw,max(1,cw//2)) if px(a,x,y)!=px(b,x,y))
if interior_changed: errs.append(f"interior changed at {interior_changed} sampled points")
# frame: pixels set outside the dialog rectangle, inside the screen
outside=sum(1 for y in range(0,H,2) for x in range(0,W,2) if not (dx0<=x<dx1 and dy0<=y<dy1) and px(a,x,y)!=px(b,x,y))
if outside<50: errs.append(f"almost nothing drawn outside the dialog ({outside} sampled px)")
# anything changed far from the dialog (more than 3 cell-widths away) is a bug
far=sum(1 for y in range(0,H,2) for x in range(0,W,2) if (x<dx0-3*cw or x>=dx1+3*cw or y<dy0-3*ch or y>=dy1+3*ch) and px(a,x,y)!=px(b,x,y))
if far: errs.append(f"{far} sampled px changed far from the dialog")
# ring really blanked: sample the middle of the ring on all four sides
for (x,y) in ((dx0+cw//2,(dy0+dy1)//2),(dx1-cw//2,(dy0+dy1)//2),((dx0+dx1)//2,dy0+ch//2),((dx0+dx1)//2,dy1-ch//2)):
    if any(px(a,x,y)): errs.append(f"ring not blank at ({x},{y})")
# PNG (RGB) for looking
try:
    from PIL import Image
    img=Image.new("RGB",(W,H))
    pix=img.load()
    for y in range(H):
        for x in range(W):
            p=px(a,x,y)
            if by==4: pix[x,y]=(p[2],p[1],p[0])
            elif by==3: pix[x,y]=(p[2],p[1],p[0])
            else:
                v=p[0]|p[1]<<8; pix[x,y]=(((v>>11)&31)*255//31,((v>>5)&63)*255//63,(v&31)*255//31)
    img.thumbnail((960,540)); img.save(png)
except Exception as e:
    errs.append("png: "+str(e))
print("OK" if not errs else "FAIL: "+"; ".join(errs))
PY
)
    if [ "$res" = "rc=0" ] && [ "$verdict" = "OK" ]; then echo "PASS: ${W}x${H} ${bpp}bpp cell ${cw}x${ch} stride+${pad}"; pass=$((pass+1))
    else echo "FAIL: ${W}x${H} ${bpp}bpp cell ${cw}x${ch}: $res $verdict"; fail=$((fail+1)); fi
done
echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
