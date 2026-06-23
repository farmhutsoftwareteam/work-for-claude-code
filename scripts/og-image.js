'use strict';

/**
 * Generates Vercel-style 1200x630 OG images per recipe at build time.
 * Uses satori (the same engine @vercel/og uses) + resvg to rasterize SVG → PNG.
 *
 * Output: docs/recipes/og/<slug>.png
 */

const fs = require('fs');
const path = require('path');
const satori = require('satori').default || require('satori');
const { Resvg } = require('@resvg/resvg-js');

const ROOT = path.resolve(__dirname, '..');
const FONTS = path.join(__dirname, 'fonts');

const FONT_BOLD = fs.readFileSync(path.join(FONTS, 'IBMPlexMono-Bold.ttf'));
const FONT_REG = fs.readFileSync(path.join(FONTS, 'IBMPlexMono-Regular.ttf'));

// Night Foundry palette
const COLORS = {
    graphite: '#0d0d0f',
    graphiteSurface: '#15151a',
    border: '#26262d',
    ivory: '#f0ece4',
    ivoryMuted: '#a8a39a',
    blue: '#4a6fa5',
    blueBright: '#6b8fc7',
};

const TYPE_COLORS = {
    workflow: '#06b6d4',
    skill: '#a78bfa',
    mcp: '#f472b6',
    hook: '#fb923c',
    command: '#facc15',
    announcement: '#e9eae8',
};

// Atelier dovetail mark — the bare ivory stroke (no squircle background) so
// it floats cleanly on the graphite OG card without a tile-within-a-tile look.
// Source: docs/atelier-mark-ivory.png (256×256, ivory mark on transparent).
const ATELIER_MARK_DATA_URI = (() => {
    const p = path.join(ROOT, 'docs', 'atelier-mark-ivory.png');
    const b64 = fs.readFileSync(p).toString('base64');
    return `data:image/png;base64,${b64}`;
})();

function typeColor(type) {
    return TYPE_COLORS[type] || COLORS.blue;
}

function typeLabel(type) {
    return (type || 'recipe').toUpperCase();
}

// JSX-like object tree for satori (no JSX runtime needed — just plain objects)
function el(type, props, ...children) {
    return { type, props: { ...props, children: children.flat().filter(Boolean) } };
}

function buildOgTree(data) {
    const accent = typeColor(data.type);

    return el('div', {
        style: {
            width: '1200px',
            height: '630px',
            display: 'flex',
            flexDirection: 'column',
            position: 'relative',
            background: COLORS.graphite,
            fontFamily: 'IBM Plex Mono',
            color: COLORS.ivory,
            padding: '64px 72px',
            overflow: 'hidden',
        },
    },
        // Subtle radial-ish glow via positioned div
        el('div', {
            style: {
                position: 'absolute',
                top: '-180px',
                right: '-180px',
                width: '600px',
                height: '600px',
                borderRadius: '600px',
                background: accent,
                opacity: 0.08,
                display: 'flex',
            },
        }),
        // Accent vertical bar on the left
        el('div', {
            style: {
                position: 'absolute',
                top: '0',
                left: '0',
                width: '6px',
                height: '630px',
                background: accent,
                display: 'flex',
            },
        }),

        // Top row: brand + type badge
        el('div', {
            style: {
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                width: '100%',
            },
        },
            el('div', {
                style: { display: 'flex', alignItems: 'center', gap: '14px' },
            },
                el('img', {
                    src: ATELIER_MARK_DATA_URI,
                    width: 40,
                    height: 40,
                    style: {
                        width: '40px',
                        height: '40px',
                        display: 'flex',
                    },
                }),
                el('span', {
                    style: {
                        fontSize: '20px',
                        fontWeight: 600,
                        color: COLORS.ivory,
                        letterSpacing: '-0.5px',
                    },
                }, 'atelier'),
                el('span', {
                    style: {
                        fontSize: '14px',
                        color: COLORS.ivoryMuted,
                        letterSpacing: '2px',
                        textTransform: 'uppercase',
                        marginLeft: '4px',
                    },
                }, '· Recipes'),
            ),
            el('div', {
                style: {
                    fontSize: '13px',
                    fontWeight: 600,
                    color: accent,
                    letterSpacing: '2px',
                    textTransform: 'uppercase',
                    padding: '8px 14px',
                    border: `1px solid ${accent}55`,
                    borderRadius: '6px',
                    background: `${accent}15`,
                    display: 'flex',
                },
            }, typeLabel(data.type))
        ),

        // Spacer
        el('div', { style: { flex: '1 1 auto', display: 'flex' } }),

        // Title
        el('div', {
            style: {
                fontSize: data.title.length > 48 ? '52px' : '64px',
                fontWeight: 700,
                lineHeight: 1.1,
                letterSpacing: '-2px',
                color: COLORS.ivory,
                marginBottom: '24px',
                display: 'flex',
                maxWidth: '1056px',
            },
        }, data.title),

        // Description (truncated for visual balance)
        data.description ? el('div', {
            style: {
                fontSize: '22px',
                lineHeight: 1.45,
                color: COLORS.ivoryMuted,
                fontWeight: 400,
                maxWidth: '900px',
                display: 'flex',
            },
        }, truncate(data.description, 140)) : null,

        // Spacer
        el('div', { style: { flex: '1 1 auto', display: 'flex' } }),

        // Bottom strip: author + URL
        el('div', {
            style: {
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                width: '100%',
                paddingTop: '24px',
                borderTop: `1px solid ${COLORS.border}`,
            },
        },
            el('span', {
                style: { fontSize: '18px', color: COLORS.ivory, fontWeight: 500, display: 'flex' },
            }, 'Munya Makosa'),
            el('span', {
                style: { fontSize: '16px', color: COLORS.ivoryMuted, fontWeight: 400, display: 'flex' },
            }, 'work.munyamakosa.com')
        ),
    );
}

function truncate(s, n) {
    if (!s || s.length <= n) return s || '';
    return s.slice(0, n - 1).trimEnd() + '…';
}

async function generateOgImage(data, outPath) {
    const tree = buildOgTree(data);
    const svg = await satori(tree, {
        width: 1200,
        height: 630,
        fonts: [
            { name: 'IBM Plex Mono', data: FONT_REG, weight: 400, style: 'normal' },
            { name: 'IBM Plex Mono', data: FONT_BOLD, weight: 700, style: 'normal' },
        ],
    });
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: 1200 } }).render().asPng();
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, png);
    return outPath;
}

module.exports = { generateOgImage };
