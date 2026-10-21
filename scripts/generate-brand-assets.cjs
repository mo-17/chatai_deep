// 从唯一矢量源生成各端品牌资源：NODE_PATH=<sharp 所在 node_modules> node scripts/generate-brand-assets.cjs
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const svgPath = path.join(root, 'branding/aipu-mark.svg');
async function png(target, size, opaque = false) {
  let pipeline = sharp(svgPath).resize(size, size);
  if (opaque) pipeline = pipeline.flatten({ background: '#6558E8' });
  const data = await pipeline.png().toBuffer();
  const file = path.join(root, target);
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, data);
  return data;
}
async function main() {
  await png('chatgpt_app_core/assets/images/aipu-mark.png', 384);
  const res = 'chatgpt_flutter/android/app/src/main/res';
  for (const [density, size] of Object.entries({ mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 })) {
    await png(`${res}/mipmap-${density}/ic_launcher.png`, size);
  }
  const vector = `<?xml version="1.0" encoding="utf-8"?>\n<!-- Generated from branding/aipu-mark.svg. -->\n<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">\n    <path android:fillColor="#6558E8" android:pathData="M248,0H776A248,248 0,0 1,1024,248V776A248,248 0,0 1,776,1024H248A248,248 0,0 1,0,776V248A248,248 0,0 1,248,0Z"/>\n    <path android:fillColor="#FFFFFF" android:pathData="M330,300H635C690,300 724,334 724,389V558C724,613 690,648 635,648H479L350,737V648H330C275,648 240,613 240,558V389C240,334 275,300 330,300Z"/>\n    <path android:fillColor="#6558E8" android:pathData="M482,365C494,424 515,446 574,458C515,470 494,492 482,551C470,492 449,470 390,458C449,446 470,424 482,365Z"/>\n    <path android:fillColor="#BCEBDC" android:pathData="M698,265a49,49 0,1 0,98 0a49,49 0,1 0,-98 0"/>\n</vector>\n`;
  await fs.writeFile(path.join(root, `${res}/drawable/aipu_mark.xml`), vector);
  const ios = 'chatgpt_flutter/ios/Runner/Assets.xcassets';
  const iosIcons = JSON.parse(await fs.readFile(path.join(root, `${ios}/AppIcon.appiconset/Contents.json`)));
  for (const entry of iosIcons.images) {
    await png(`${ios}/AppIcon.appiconset/${entry.filename}`, Math.round(parseFloat(entry.size) * parseFloat(entry.scale)), true);
  }
  for (const scale of [1, 2, 3]) await png(`${ios}/LaunchImage.imageset/LaunchImage${scale === 1 ? '' : `@${scale}x`}.png`, 96 * scale);
  for (const size of [16, 32, 64, 128, 256, 512, 1024]) await png(`chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png`, size);
  for (const size of [192, 512]) {
    await png(`chatgpt_flutter/web/icons/Icon-${size}.png`, size);
    await png(`chatgpt_flutter/web/icons/Icon-maskable-${size}.png`, size, true);
  }
  await png('chatgpt_flutter/web/favicon.png', 32);
  await png('chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png', 1024);
  await png('chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png', 1024);
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const images = await Promise.all(sizes.map(size => sharp(svgPath).resize(size, size).png().toBuffer()));
  const header = Buffer.alloc(6 + 16 * images.length);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach((data, i) => {
    const at = 6 + 16 * i;
    header[at] = sizes[i] === 256 ? 0 : sizes[i]; header[at + 1] = header[at];
    header.writeUInt16LE(1, at + 4); header.writeUInt16LE(32, at + 6);
    header.writeUInt32LE(data.length, at + 8); header.writeUInt32LE(offset, at + 12); offset += data.length;
  });
  await fs.writeFile(path.join(root, 'chatgpt_flutter/windows/runner/resources/app_icon.ico'), Buffer.concat([header, ...images]));
  const symbol = await sharp(path.join(root, 'branding/aipu-splash-symbol.svg')).resize(720, 720).png().toBuffer();
  for (const target of [
    'chatgpt_app_core/assets/images/aipu-splash-symbol.png',
    'chatgpt_flutter/android/app/src/main/res/drawable-nodpi/aipu_splash_symbol.png',
  ]) {
    const file = path.join(root, target); await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, symbol);
  }
  for (const scale of [1, 2, 3]) {
    const file = path.join(root, `${ios}/LaunchImage.imageset/LaunchImage${scale === 1 ? '' : `@${scale}x`}.png`);
    await sharp(path.join(root, 'branding/aipu-splash-symbol.svg')).resize(240 * scale, 240 * scale).png().toFile(file);
  }
  const backdropDir = path.join(root, `${ios}/LaunchBackdrop.imageset`);
  await fs.mkdir(backdropDir, { recursive: true });
  for (const mode of ['light', 'dark']) {
    const image = await sharp(path.join(root, `branding/aipu-splash-backdrop-${mode}.svg`)).resize(780, 1688).png().toBuffer();
    for (const target of [
      `chatgpt_app_core/assets/images/aipu-splash-backdrop-${mode}.png`,
      `chatgpt_flutter/android/app/src/main/res/${mode === 'dark' ? 'drawable-night-nodpi' : 'drawable-nodpi'}/aipu_launch_backdrop.png`,
      `${ios}/LaunchBackdrop.imageset/backdrop-${mode}.png`,
    ]) {
      const file = path.join(root, target); await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, image);
    }
  }
  await fs.writeFile(path.join(backdropDir, 'Contents.json'), JSON.stringify({ images: [
    { idiom: 'universal', filename: 'backdrop-light.png' },
    { idiom: 'universal', filename: 'backdrop-dark.png', appearances: [{ appearance: 'luminosity', value: 'dark' }] },
  ], info: { version: 1, author: 'xcode' } }, null, 2) + '\n');
  console.log('Generated Aipu brand and splash assets from branding/*.svg.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
