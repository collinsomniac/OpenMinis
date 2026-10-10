#!/usr/bin/env python3
"""Build scalable geometric nabla/harp SVGs from design.json."""
import json, math
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
C=json.loads((ROOT/'design.json').read_text())
OUT=ROOT/'source'
OUT.mkdir(exist_ok=True)

def num(v):
    return f'{v:.6f}'.rstrip('0').rstrip('.')

def geometry():
    q=C['triangle']
    w,t,inset,cx=q['width'],q['top'],q['band_width'],q['center_x']
    h=w*math.sqrt(3)/2
    left,right,bottom=cx-w/2,cx+w/2,t+h
    il,ir=left+math.sqrt(3)*inset,right-math.sqrt(3)*inset
    it,ib=t+inset,bottom-2*inset
    d=f'M {num(left)} {num(t)} L {num(right)} {num(t)} L {num(cx)} {num(bottom)} Z '
    d+=f'M {num(il)} {num(it)} L {num(ir)} {num(it)} L {num(cx)} {num(ib)} Z'
    return d,il,ir,it,ib

def string_paths(count):
    _,il,ir,it,ib=geometry()
    q=C['strings']
    half=q['width']/2
    overlap=q['end_overlap']
    blank=q['blank_end_slots']
    # Direction matches the left diagonal (60 degrees), not vertical bars.
    ux,uy=0.5,math.sqrt(3)/2
    nx,ny=-uy,ux
    out=[]
    for i in range(count):
        u=(i+blank)/(count-1+2*blank)
        sx=il+u*(ir-il)
        sy=it
        ey=it+(ir-sx)*math.sqrt(3)/2
        ex=sx+(ey-it)/math.sqrt(3)
        # Hide the ends slightly inside the top and right rails for clean joins.
        a=(sx-ux*overlap,sy-uy*overlap)
        b=(ex+ux*overlap,ey+uy*overlap)
        pts=[(a[0]+nx*half,a[1]+ny*half),(b[0]+nx*half,b[1]+ny*half),
             (b[0]-nx*half,b[1]-ny*half),(a[0]-nx*half,a[1]-ny*half)]
        d='M '+' L '.join(f'{num(x)} {num(y)}' for x,y in pts)+' Z'
        out.append(f'<path id="string-{i+1:02d}" d="{d}"/>')
    return '\n      '.join(out)

def svg(count=None,layer='all',presentation=False):
    count=count or C['strings']['count']
    bg,fg,shadow=C['background'],C['foreground'],C['shadow']
    dx,dy=shadow['offset_x'],shadow['offset_y']
    d,il,ir,it,ib=geometry()
    defs=f'''<defs>
    <linearGradient id="coral-gradient" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{bg['top']}"/><stop offset="1" stop-color="{bg['bottom']}"/>
    </linearGradient>
    <radialGradient id="coral-light" cx="420" cy="170" r="850" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffffff" stop-opacity="{bg['highlight_opacity']}"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="lavender-gradient" x1="500" y1="170" x2="500" y2="886" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{fg['top']}"/><stop offset="1" stop-color="{fg['bottom']}"/>
    </linearGradient>
    <linearGradient id="tile-rim" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#b92949"/><stop offset="1" stop-color="#cf3350"/>
    </linearGradient>
    <path id="triangle-ring" d="{d}" fill-rule="evenodd" clip-rule="evenodd"/>
    <!-- Foreground and shadow reuse this complete harp, including its strings. -->
    <g id="harp-symbol">
      <use href="#triangle-ring" xlink:href="#triangle-ring"/>
      <g id="harp-strings">
      {string_paths(count)}
      </g>
    </g>
    <!-- Exactly one feather; no feDropShadow and no foreground shadow. -->
    <filter id="shadow-feather" x="30" y="80" width="960" height="900" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feGaussianBlur stdDeviation="{shadow['feather_sigma']}"/>
    </filter>
  </defs>'''
    body=[]
    if layer in ('all','background'):
        rounded=' rx="252"' if presentation else ''
        # No stroke along the inner panel: coral meets crimson directly.
        body.append(f'<g id="background" inkscape:groupmode="layer" inkscape:label="Coral background"><rect width="1024" height="1024"{rounded} fill="url(#tile-rim)"/><rect x="40" y="40" width="944" height="944" rx="214" fill="url(#coral-gradient)"/><rect x="40" y="40" width="944" height="944" rx="214" fill="url(#coral-light)"/></g>')
    if layer in ('all','shadow','mark'):
        body.append(f'<g id="shadow" inkscape:groupmode="layer" inkscape:label="Purple harp shadow" transform="translate({num(dx)} {num(dy)})" opacity="{shadow["opacity"]}"><use href="#harp-symbol" xlink:href="#harp-symbol" fill="{shadow["color"]}" filter="url(#shadow-feather)"/></g>')
    if layer in ('all','foreground','mark'):
        body.append('<g id="foreground" inkscape:groupmode="layer" inkscape:label="Lavender harp foreground"><use href="#harp-symbol" xlink:href="#harp-symbol" fill="url(#lavender-gradient)"/></g>')
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">Nabla geometric harp — {count} strings</title>
  <desc id="desc">An enlarged lavender nabla with {count} individually editable diagonal strings, one-and-a-half unused string spacings at both ends, and one dark purple same-size feathered shadow. The coral panel meets its crimson rim without a highlight outline.</desc>
  {defs}
  {chr(10).join(body)}
</svg>
'''

files=[('icon.svg',C['strings']['count'],'all',False),
       ('icon-six-strings.svg',6,'all',False),('icon-seven-strings.svg',7,'all',False),('icon-eight-strings.svg',8,'all',False),
       ('presentation.svg',C['strings']['count'],'all',True),
       ('background.svg',C['strings']['count'],'background',False),
       ('foreground.svg',C['strings']['count'],'foreground',False),
       ('shadow.svg',C['strings']['count'],'shadow',False),
       ('mark.svg',C['strings']['count'],'mark',False)]
for name,count,layer,presentation in files:
    (OUT/name).write_text(svg(count,layer,presentation))
print(f'Built {len(files)} SVGs; default {C["strings"]["count"]} strings.')
