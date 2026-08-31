#!/usr/bin/env python3
"""Подобрать поправку баланса белого для задней камеры по замеру."""
import json, subprocess, sys, os, re
BASE = json.load(open('ccm_rear_base.json'))     # заводская OV8865 D65
FRAC = 0.5
def build(gR, gB):
    C=[BASE[0:3],BASE[3:6],BASE[6:9]]
    I=[[1,0,0],[0,1,0],[0,0,1]]
    M=[[(1-FRAC)*I[i][j]+FRAC*C[i][j] for j in range(3)] for i in range(3)]
    g=(gR,1.0,gB)
    return [[M[i][j]*g[j] for j in range(3)] for i in range(3)]   # столбцы = вход
def install(M):
    body=",\n                 ".join(", ".join(f"{v:7.4f}" for v in r) for r in M)
    open('/tmp/r.yaml','w').write(
"%YAML 1.1\n---\nversion: 1\nalgorithms:\n  - BlackLevel:\n  - Awb:\n  - Ccm:\n"
"      ccms:\n        - ct: 6500\n          ccm: [ "+body+" ]\n  - Adjust:\n  - Agc:\n...\n")
    subprocess.run("echo 'fuckyerass' | sudo -S -p '' install -m 644 -o root -g root "
                   "/tmp/r.yaml /usr/share/libcamera/ipa/simple/ov13858.yaml",
                   shell=True, capture_output=True)
def measure():
    subprocess.run("rm -f t.rgb", shell=True)
    subprocess.run("timeout -k 3 12 gst-launch-1.0 -q libcamerasrc "
        "camera-name='\\\\_SB_.PC00.I2C3.CAMR' ! video/x-raw,width=1280,height=720 "
        "! videoconvert ! video/x-raw,format=RGB ! filesink location=t.rgb",
        shell=True, capture_output=True)
    fs=1280*720*3
    if not os.path.exists('t.rgb'): return None
    n=os.path.getsize('t.rgb')//fs
    if n<3: return None
    f=open('t.rgb','rb'); f.seek(fs*(n-2)); b=f.read(fs)
    rs=gs=bs=0; c=0
    for i in range(0,fs-3,3*47):
        r,g,bl=b[i],b[i+1],b[i+2]
        if max(r,g,bl)<250: rs+=r; gs+=g; bs+=bl; c+=1
    return rs/c, gs/c, bs/c
gR=gB=1.0
for it in range(4):
    install(build(gR,gB))
    m=measure()
    if not m: print("  камера занята"); sys.exit(1)
    R,G,B=m
    print(f"  итерация {it}: столбцы R×{gR:.3f} B×{gB:.3f}  ->  R/G={R/G:.3f} B/G={B/G:.3f}")
    if abs(R/G-1)<0.02 and abs(B/G-1)<0.02:
        print("  сошлось"); break
    gR *= (G/R)**0.6
    gB *= (G/B)**0.6
M=build(gR,gB)
print("\n  итоговая матрица:")
for r in M: print("   ", ", ".join(f"{v:8.4f}" for v in r))
print("  суммы строк:", [round(sum(r),3) for r in M], "(единица тут НЕ нужна — компенсируем перекос)")
json.dump({'gR':gR,'gB':gB}, open('wb_rear.json','w'))
