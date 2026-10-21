"""Bundle the accepted 20 paired animations; preserve source pixels and timings."""
from pathlib import Path
import hashlib
import json
import math

import numpy as np
from PIL import Image, ImageDraw, ImageSequence

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT/'output/chat-decoration-20styles-20261022'
OUTPUT = ROOT/'chat_message/assets/decoration'
DOCS = ROOT/'chat_message/design/paired-animated-20261022'
GEOMETRY = ROOT/'chat_message/lib/theme/chat_paired_asset_geometry.dart'
NAMES = [
    'crimsonPhoenix', 'frostPalace', 'fireflyGrove', 'cherrySoda',
    'honeyGarden', 'pandaBamboo', 'shibaPost', 'catMagic', 'orbitalVoyage',
    'circuitMatrix', 'jadeFiligree', 'dunhuangRibbons', 'imperialPeony',
    'bluePorcelain', 'koiLotus', 'ginkgoLetter', 'mushroomFable',
    'carnivalDream', 'orangeSummer', 'royalChess',
]


def descriptor(path):
    return {'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def opening(image):
    alpha = np.asarray(image)[:, :, 3]
    clear = Image.fromarray(np.where(alpha < 8, 255, 0).astype('uint8')).copy()
    ImageDraw.floodfill(clear, (image.width//2, image.height//2), 128)
    ys, xs = np.nonzero(np.asarray(clear) == 128)
    box = (int(xs.min()), int(ys.min()), int(xs.max()+1), int(ys.max()+1))
    assert box[0] > 0 and box[1] > 0 and box[2] < image.width and box[3] < image.height
    return box


def avatar_inset(frames):
    # 头像覆盖透明孔的最远半径，边框盖在头像之上，不在孔内留下细缝。
    radii = []
    for image in frames:
        alpha = np.asarray(image)[:, :, 3]
        for angle in np.linspace(0, math.tau, 128, endpoint=False):
            rs = np.arange(20, 110, .5)
            xs = np.rint(128+np.cos(angle)*rs).astype(int)
            ys = np.rint(128+np.sin(angle)*rs).astype(int)
            hits = np.flatnonzero(alpha[ys, xs] > 100)
            if len(hits): radii.append(float(rs[hits[0]]))
    radius = float(np.percentile(radii, 95))+1
    assert 45 < radius < 100
    return round(.5-radius/256, 6)


def main():
    themes = json.loads((SOURCE/'source-plan.json').read_text())
    assert len(themes) == len(NAMES) == 20
    OUTPUT.mkdir(exist_ok=True)
    DOCS.mkdir(parents=True, exist_ok=True)
    sets, geometry = [], []
    for theme, name in zip(themes, NAMES):
        entry = {'id': name, 'sourceId': theme['id'], 'label': theme['name'],
                 'generator': 'built-in imagegen', 'files': {}, 'sourceFrames': {}}
        images = {}
        for kind, suffix in [('avatar', 'frame'), ('bubble', 'bubble')]:
            paths = [SOURCE/theme['id']/kind/f'frames/{i:02}.png' for i in range(1,7)]
            frames = [Image.open(p).convert('RGBA') for p in paths]
            images[kind] = frames
            movie, poster = OUTPUT/f'{name}_{suffix}.webp', OUTPUT/f'{name}_{suffix}_poster.webp'
            frames[0].save(movie, save_all=True, append_images=frames[1:],
                           duration=180, loop=0, lossless=True, method=6)
            frames[0].save(poster, lossless=True, method=6)
            with Image.open(movie) as decoded:
                assert decoded.n_frames == 6 and decoded.info['loop'] == 0
                hashes = set()
                for i, frame in enumerate(ImageSequence.Iterator(decoded)):
                    rgba = np.asarray(frame.convert('RGBA'))
                    expected = np.asarray(frames[i])
                    assert frame.info.get('duration',180) == 180
                    assert np.array_equal(rgba[:,:,3], expected[:,:,3])
                    mask = expected[:,:,3] > 0
                    assert np.array_equal(rgba[mask], expected[mask])
                    assert rgba[frame.height//2,frame.width//2,3] == 0
                    hashes.add(hashlib.sha256(rgba.tobytes()).hexdigest())
                assert len(hashes) == 6
            entry['files'][kind] = descriptor(movie)
            entry['files'][kind+'Poster'] = descriptor(poster)
            entry['sourceFrames'][kind] = [descriptor(p) for p in paths]
        boxes = [opening(im) for im in images['bubble']]
        # 底色只铺到内孔边缘之下，避免透明外沿露出矩形底板。
        inset = [round(max(0,min(b[0] for b in boxes)/4-1),3),
                 round(max(0,min(b[1] for b in boxes)/4-1),3),
                 round(max(0,(512-max(b[2] for b in boxes))/4-1),3),
                 round(max(0,(320-max(b[3] for b in boxes))/4-1),3)]
        frame_inset = avatar_inset(images['avatar'])
        entry.update(avatarInset=frame_inset, bubbleBackgroundInsets=inset,
                     frameCount=6, frameDurationMs=180, loopMs=1080,
                     frameSize=[256,256],bubbleSize=[512,320],bubbleScale=4,
                     bubbleCenterSlicePixels=[200,156,312,164])
        geometry.append(f"  '{name}': (avatarInset: {frame_inset}, bubbleInsets: EdgeInsets.fromLTRB({', '.join(map(str,inset))})),")
        sets.append(entry)
        print(name+': avatar and bubble, 6 frames each, alpha and timing verified',flush=True)
    GEOMETRY.write_text("// 由 scripts/prepare-chat-decoration-20styles.py 从已确认帧测量生成。\n"
                        "import 'package:flutter/painting.dart';\n\n"
                        "const chatPairedAssetGeometry = <String, ({double avatarInset, EdgeInsets bubbleInsets})>{\n"
                        +'\n'.join(geometry)+'\n};\n')
    (DOCS/'manifest.json').write_text(json.dumps({'generator':'built-in imagegen',
        'sets':sets,'runtimeBytes':sum(v['bytes'] for s in sets for v in s['files'].values())},
        ensure_ascii=False,indent=2)+'\n')
    for theme in themes:
        selected_prompt = SOURCE/theme['id']/theme.get('promptFile','prompt-used.txt')
        theme['acceptedPrompt'] = selected_prompt.read_text().strip()
    (DOCS/'prompts.json').write_text(json.dumps(themes,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'styles':20,'runtimeFiles':80,'runtimeBytes':sum(v['bytes'] for s in sets for v in s['files'].values())}))


if __name__ == '__main__':
    main()
