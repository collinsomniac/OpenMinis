#!/usr/bin/env python3
"""Render SVGs with Inkscape, export iOS catalogs, and verify every output."""
import argparse, copy, hashlib, json, os, shutil, subprocess, tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parents[1]
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
SLOTS = [
    ('iphone','20x20','2x',40), ('iphone','20x20','3x',60),
    ('iphone','29x29','2x',58), ('iphone','29x29','3x',87),
    ('iphone','40x40','2x',80), ('iphone','40x40','3x',120),
    ('iphone','60x60','2x',120), ('iphone','60x60','3x',180),
    ('ipad','20x20','1x',20), ('ipad','20x20','2x',40),
    ('ipad','29x29','1x',29), ('ipad','29x29','2x',58),
    ('ipad','40x40','1x',40), ('ipad','40x40','2x',80),
    ('ipad','76x76','1x',76), ('ipad','76x76','2x',152),
    ('ipad','83.5x83.5','2x',167), ('ios-marketing','1024x1024','1x',1024),
]

def render(src, dst, size, opaque):
    dst.parent.mkdir(parents=True,exist_ok=True)
    # Atomic output prevents consumers from seeing a partly written PNG.
    with tempfile.TemporaryDirectory(prefix='triangle-icon-render-') as scratch:
        raw=Path(scratch)/'render.png'
        final=Path(scratch)/'final.png'
        subprocess.run(['inkscape',str(src),'--export-area-page',f'--export-width={size}',f'--export-height={size}',f'--export-filename={raw}'],check=True,capture_output=True)
        with Image.open(raw) as original:
            im=original.convert('RGBA')
        if opaque:
            if im.getchannel('A').getextrema() != (255,255):
                raise ValueError(f'Unexpected transparent pixels in {dst}')
            im=im.convert('RGB')
        im.save(final,icc_profile=ICC)
        with Image.open(final) as check:
            check.load()
            assert check.size==(size,size)
        os.replace(final,dst)
    return dst

def write_catalog(folder, images):
    folder.mkdir(parents=True,exist_ok=True)
    (folder/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
    for name in set(x['filename'] for x in images):
        shutil.copy2(ROOT/'png'/name,folder/name)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--strings',type=int,choices=[6,7,8],default=None)
    args=parser.parse_args()
    design=json.loads((ROOT/'design.json').read_text())
    count=args.strings or design['strings']['count']
    names={6:'six',7:'seven',8:'eight'}
    master=ROOT/'source'/('icon.svg' if count==design['strings']['count'] else f'icon-{names[count]}-strings.svg')
    # Derive aligned layer files from the chosen master, including direct SVG edits.
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    ET.register_namespace('xlink', 'http://www.w3.org/1999/xlink')
    ET.register_namespace('inkscape', 'http://www.inkscape.org/namespaces/inkscape')
    source_root=ET.parse(master).getroot()
    for name in ['background','shadow','foreground','mark']:
        root=copy.deepcopy(source_root)
        keep=['shadow','foreground'] if name=='mark' else [name]
        for node in list(root):
            if node.tag=='{http://www.w3.org/2000/svg}g' and node.get('id') not in keep:
                root.remove(node)
        ET.ElementTree(root).write(ROOT/'source'/(name+'.svg'),encoding='utf-8',xml_declaration=True)
    # Derive the rounded presentation from the selected production source, too.
    rounded=copy.deepcopy(source_root)
    panel=rounded.find('{http://www.w3.org/2000/svg}g[@id="background"]')
    panel.find('{http://www.w3.org/2000/svg}rect').set('rx','252')
    ET.ElementTree(rounded).write(ROOT/'source'/'presentation.svg',encoding='utf-8',xml_declaration=True)
    sizes=sorted(set([s[3] for s in SLOTS]+[512,2048,4096]))
    jobs=[(master,ROOT/'png'/f'icon-{n}.png',n,True) for n in sizes]
    jobs += [(ROOT/'source'/(name+'.svg'),ROOT/'icon-composer-layers'/(name+'.png'),1024,name=='background') for name in ['background','shadow','foreground']]
    jobs += [(ROOT/'source'/'presentation.svg',ROOT/'preview'/'presentation.png',1024,False)]
    jobs += [(ROOT/'source'/f'icon-{word}-strings.svg',ROOT/'preview'/f'{word}-strings-square.png',1024,True) for word in ['six','seven','eight']]
    for job in jobs:
        print(render(*job).relative_to(ROOT))
    write_catalog(ROOT/'ios-single-size'/'AppIcon.appiconset',[
        {'filename':'icon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}
    ])
    write_catalog(ROOT/'ios-all-sizes'/'AppIcon.appiconset',[
        {'filename':f'icon-{n}.png','idiom':idiom,'size':size,'scale':scale} for idiom,size,scale,n in SLOTS
    ])
    # Validate every catalog reference, physical dimensions, RGB mode, and sRGB metadata.
    checked=[]
    for catalog in [ROOT/'ios-single-size'/'AppIcon.appiconset',ROOT/'ios-all-sizes'/'AppIcon.appiconset']:
        data=json.loads((catalog/'Contents.json').read_text())
        for slot in data['images']:
            p=catalog/slot['filename']
            expected=int(float(slot['size'].split('x')[0])*float(slot.get('scale','1x').rstrip('x')))
            with Image.open(p) as im:
                im.load()
                assert im.size==(expected,expected),(p,im.size,expected)
                assert im.mode=='RGB',(p,im.mode)
                assert im.info.get('icc_profile'),p
            checked.append(str(p.relative_to(ROOT)))
    for p in (ROOT/'png').glob('*.png'):
        with Image.open(p) as im:
            im.load()
            assert im.mode=='RGB' and im.width==im.height
    for p in (ROOT/'icon-composer-layers').glob('*.png'):
        with Image.open(p) as im:
            im.load()
            assert im.size==(1024,1024)
            assert im.mode==('RGB' if p.stem=='background' else 'RGBA')
    actual_strings=len(source_root.find('.//{http://www.w3.org/2000/svg}g[@id="harp-strings"]'))
    manifest={'revision':'nabla-harp-v3','strings':actual_strings,'source':str(master.relative_to(ROOT)),
        'shadow_transform':source_root.find('{http://www.w3.org/2000/svg}g[@id="shadow"]').get('transform'),
        'end_spacing_in_string_pitches':design['strings']['blank_end_slots'],
        'linear_scale_from_previous_revision':design['triangle'].get('scale_from_v2',1),
        'source_sha256':hashlib.sha256(master.read_bytes()).hexdigest(),
        'pixel_sizes':sizes,'catalog_slots_checked':len(checked),
        'color_space':'sRGB','icon_alpha_channel':False,
        'validation':'All PNG dimensions, catalog references, RGB mode, and color profiles passed. Xcode compilation requires a Mac and has not been performed.'}
    (ROOT/'export-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2))

if __name__=='__main__':
    main()
