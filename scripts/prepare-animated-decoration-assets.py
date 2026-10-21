"""Bundle accepted imagegen art; only alignment, resampling, encoding and QC.

Requires Pillow and NumPy. Run from the repository root after source art exists.
No drawing, image generation, network requests or credentials are used here.
"""
from pathlib import Path
import hashlib
import json
import math

import numpy as np
from PIL import Image, ImageSequence

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'output/chat-decoration-concepts-20261021-v2'
BUBBLES = SOURCE / 'integration-bubbles'
OUTPUT = ROOT / 'chat_message/assets/decoration'
DOCS = ROOT / 'chat_message/design/animated-20261022'
THEMES = [
    ('butterflyGlass', '01-butterfly-glass', '蝶影琉璃'),
    ('dragonEmber', '02-dragon-ember', '龙焰赤金'),
    ('midnightRose', '03-midnight-rose', '暗夜蔷薇'),
    ('cloudFeather', '04-cloud-feather', '云羽圣歌'),
    ('moonRabbit', '05-moon-rabbit', '月兔绮梦'),
    ('abyssGlow', '06-abyss-glow', '深海荧光'),
    ('foxCharm', '07-fox-charm', '狐火御守'),
    ('creamBakery', '08-cream-bakery', '奶油烘焙'),
    ('streetGraffiti', '09-street-graffiti', '街头涂鸦'),
    ('vinylJazz', '10-vinyl-jazz', '黑胶爵士'),
]


def circle_center(image):
    """Inner circle anchor for the original butterfly sheet."""
    alpha = np.asarray(image)[:, :, 3]
    points = []
    for angle in np.linspace(0, math.tau, 96, endpoint=False):
        radii = np.arange(45, 176, .5)
        xs = np.rint(192 + np.cos(angle) * radii).astype(int)
        ys = np.rint(192 + np.sin(angle) * radii).astype(int)
        hits = np.flatnonzero(alpha[ys, xs] > 180)
        if hits.size:
            points.append((float(xs[hits[0]]), float(ys[hits[0]])))
    points = np.array(points)
    assert len(points) >= 48
    for _ in range(5):
        x, y = points.T
        cx, cy, c = np.linalg.lstsq(
            np.column_stack((2*x, 2*y, np.ones(len(x)))), x*x+y*y, rcond=None)[0]
        radius = math.sqrt(max(0, c+cx*cx+cy*cy))
        error = np.abs(np.hypot(x-cx, y-cy)-radius)
        keep = error < max(3, float(np.median(error))*2.6)
        if keep.all() or keep.sum() < 40:
            break
        points = points[keep]
    assert 60 < radius < 175 and abs(cx-192) < 35 and abs(cy-192) < 35
    return cx, cy


def descriptor(path):
    return {'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    DOCS.mkdir(parents=True, exist_ok=True)
    sets = []
    for name, source_id, label in THEMES:
        frames, sources = [], []
        for index in range(1, 10):
            path = (SOURCE/f'animation/processed/idle-{index}.png' if name == 'butterflyGlass'
                    else SOURCE/f'animation/sets/{source_id}/frames/frame-{index:02}.png')
            image = Image.open(path).convert('RGBA')
            if name == 'butterflyGlass':
                cx, cy = circle_center(image)
                dx, dy = round(192-cx), round(192-cy)
                box = image.getbbox()
                assert box[0]+dx > 0 and box[1]+dy > 0
                assert box[2]+dx < 384 and box[3]+dy < 384
                aligned = Image.new('RGBA', image.size)
                aligned.paste(image, (dx, dy))  # no alpha mask: preserve alpha
                image = aligned
            frames.append(image.resize((256, 256), Image.Resampling.LANCZOS))
            sources.append(descriptor(path))
        movie = OUTPUT/f'{name}_frame.webp'
        poster = OUTPUT/f'{name}_frame_poster.webp'
        frames[0].save(movie, save_all=True, append_images=frames[1:],
                       duration=120, loop=0, lossless=True, method=6)
        frames[0].save(poster, lossless=True, method=6)
        hashes, durations = set(), []
        with Image.open(movie) as decoded:
            assert decoded.n_frames == 9 and decoded.info['loop'] == 0
            for index, frame in enumerate(ImageSequence.Iterator(decoded)):
                rgba = np.asarray(frame.convert('RGBA'))
                source = np.asarray(frames[index])
                assert rgba[128, 128, 3] == 0
                assert all(rgba[y, x, 3] == 0 for x in [0, 255] for y in [0, 255])
                assert np.array_equal(rgba[:, :, 3], source[:, :, 3])
                mask = source[:, :, 3] > 0
                assert np.array_equal(rgba[mask], source[mask])
                hashes.add(hashlib.sha256(rgba.tobytes()).hexdigest())
                durations.append(frame.info.get('duration', 120))
        assert len(hashes) == 9 and durations == [120]*9
        bubble_source = BUBBLES/f'{name}.png'
        bubble = Image.open(bubble_source).convert('RGBA')
        assert abs(bubble.width/bubble.height-2) < .02
        bubble = bubble.resize((1024, 512), Image.Resampling.LANCZOS)
        assert bubble.getpixel((512, 256))[3] < 3
        bubble_path = OUTPUT/f'{name}_bubble.webp'
        bubble.save(bubble_path, lossless=True, method=6)
        sets.append({'id': name, 'label': label, 'sourceId': source_id,
                     'sourceFrames': sources, 'bubbleSource': descriptor(bubble_source),
                     'animation': descriptor(movie), 'poster': descriptor(poster),
                     'bubble': descriptor(bubble_path), 'frameSize': [256, 256],
                     'frameCount': 9, 'frameDurationMs': 120, 'loopMs': 1080,
                     'bubbleSize': [1024, 512], 'bubbleScale': 8,
                     'bubbleCenterSlicePixels': [256, 246, 768, 266]})
        print(f'{name}: 9 distinct RGBA frames, 120ms, alpha preserved, bubble clear', flush=True)
    (DOCS/'manifest.json').write_text(json.dumps({
        'generator': 'built-in imagegen', 'sets': sets,
        'runtimeBytes': sum(item[k]['bytes'] for item in sets
                            for k in ['animation', 'poster', 'bubble'])
    }, ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
