// Render macOS AppIcon set from the Atelier dovetail tile SVG.
// Uses the exact spec from the designer's handoff (generate-icons.mjs):
//   - graphite squircle (#232120) at 22% corner radius
//   - ivory mark (#e8e2d5) centered at 54% of the canvas
//   - dovetail seam: M32 7 L32 24 L46 28 L46 36 L32 40 L32 57
//
// Writes app_icon_{16,32,64,128,256,512,1024}.png into the AppIcon.appiconset
// directory, replacing the prior icons.
//
//   node scripts/build-app-icons.mjs
import sharp from 'sharp';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const INK = '#232120';
const PAPER = '#e8e2d5';
const SEAM = 'M32 7 L32 24 L46 28 L46 36 L32 40 L32 57';
const SIZES = [16, 32, 64, 128, 256, 512, 1024];
const OUT_DIR = 'Sources/Assets.xcassets/AppIcon.appiconset';

function tileSVG(s) {
    const r = Math.round(s * 0.22);
    const m = s * 0.54;
    const o = (s - m) / 2;
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}">
<rect x="0" y="0" width="${s}" height="${s}" rx="${r}" ry="${r}" fill="${INK}"/>
<g transform="translate(${o} ${o}) scale(${m / 64})">
<rect x="7" y="7" width="50" height="50" fill="none" stroke="${PAPER}" stroke-width="6" stroke-linecap="square" stroke-linejoin="miter"/>
<path d="${SEAM}" fill="none" stroke="${PAPER}" stroke-width="6" stroke-linecap="square" stroke-linejoin="miter"/>
</g></svg>`;
}

for (const s of SIZES) {
    const out = join(OUT_DIR, `app_icon_${s}.png`);
    const buf = await sharp(Buffer.from(tileSVG(s))).resize(s, s).png().toBuffer();
    await writeFile(out, buf);
    console.log('✓', out);
}
