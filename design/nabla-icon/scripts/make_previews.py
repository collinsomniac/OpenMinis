#!/usr/bin/env python3
"""Create rounded icon previews, revision comparison, and actual-size sheet."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'preview'
OUT.mkdir(exist_ok=True)
BG='#2e2f33'
FONT='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'

def masked(im,size):
    im=im.convert('RGBA').resize((size,size),Image.Resampling.LANCZOS)
    hi=size*4
    mask=Image.new('L',(hi,hi))
    ImageDraw.Draw(mask).rounded_rectangle((0,0,hi-1,hi-1),radius=hi*252/1024,fill=255)
    im.putalpha(mask.resize((size,size),Image.Resampling.LANCZOS))
    return im

def font(n):
    return ImageFont.truetype(FONT,n) if Path(FONT).exists() else ImageFont.load_default()

with Image.open(ROOT/'png/icon-1024.png') as im:
    main=masked(im,480)
main.save(OUT/'icon-preview.png')

sheet=Image.new('RGB',(1020,430),BG)
draw=ImageDraw.Draw(sheet)
for i,word in enumerate(['six','seven','eight']):
    with Image.open(OUT/f'{word}-strings-square.png') as im:
        tile=masked(im,300)
    x=20+i*340
    sheet.paste(tile,(x,28),tile)
    draw.text((x,350),f'{word.capitalize()} strings'+(' — default' if word=='seven' else ''),font=font(21),fill='white')
    draw.text((x,384),'1.5 unused string spacings at each end',font=font(15),fill='#c6c7cd')
sheet.save(OUT/'string-options.png')

sheet=Image.new('RGB',(800,510),BG)
draw=ImageDraw.Draw(sheet)
items=[(ROOT/'reference/previous-harp-v2.png','Previous harp','Smaller frame; evenly spread strings'),
       (ROOT/'png/icon-1024.png','Revised nabla harp','20% larger; more end space; equal X/Y')]
for i,(p,label,caption) in enumerate(items):
    with Image.open(p) as im: tile=masked(im,360)
    x=20+i*400
    sheet.paste(tile,(x,24),tile)
    draw.text((x,411),label,font=font(23),fill='white')
    draw.text((x,452),caption,font=font(16),fill='#c6c7cd')
sheet.save(OUT/'comparison.png')

sizes=[20,29,40,58,60,76,80,87,120,152,167,180]
sheet=Image.new('RGB',(1060,510),BG)
draw=ImageDraw.Draw(sheet)
draw.text((28,20),'Nabla harp — actual pixel sizes',font=font(24),fill='white')
for i,n in enumerate(sizes):
    x=28+(i%6)*170
    y=80+(i//6)*210
    with Image.open(ROOT/'png'/f'icon-{n}.png') as im: tile=masked(im,n)
    sheet.paste(tile,(x+(150-n)//2,y+(180-n)//2),tile)
    draw.text((x+45,y+184),f'{n} px',font=font(16),fill='#c6c7cd')
sheet.save(OUT/'size-sheet.png')
print(f'Created previews in {OUT}')
