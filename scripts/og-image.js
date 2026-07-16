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

const CLAUDE_CORAL = '#D97757';
const CHATGPT_GREEN = '#10A37F';
const CLAUDE_MARK_PATH = 'm4.714 15.956 4.718-2.648.079-.23-.08-.128h-.23l-.79-.048-2.695-.073-2.337-.097-2.265-.122-.57-.121-.535-.704.055-.353.48-.321.685.06 1.518.104 2.277.157 1.651.098 2.447.255h.389l.054-.158-.133-.097-.103-.098-2.356-1.596-2.55-1.688-1.336-.972-.722-.491L2 6.223l-.158-1.008.656-.722.88.06.224.061.893.686 1.906 1.476 2.49 1.833.364.304.146-.104.018-.072-.164-.274-1.354-2.446-1.445-2.49-.644-1.032-.17-.619a3 3 0 0 1-.103-.729L6.287.133 6.7 0l.995.134.42.364.619 1.415L9.735 4.14l1.555 3.03.455.898.243.832.09.255h.159V9.01l.127-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.583.28.48.685-.067.444-.286 1.851-.558 2.903-.365 1.942h.213l.243-.242.983-1.306 1.652-2.064.728-.82.85-.904.547-.431h1.032l.759 1.129-.34 1.166-1.063 1.347-.88 1.142-1.263 1.7-.79 1.36.074.11.188-.02 2.853-.606 1.542-.28 1.84-.315.832.388.09.395-.327.807-1.967.486-2.307.462-3.436.813-.043.03.049.061 1.548.146.662.036h1.62l3.018.225.79.522.473.638-.08.485-1.213.62-1.64-.389-3.825-.91-1.31-.329h-.183v.11l1.093 1.068 2.003 1.81 2.508 2.33.127.578-.321.455-.34-.049-2.204-1.657-.85-.747-1.925-1.62h-.127v.17l.443.649 2.343 3.521.122 1.08-.17.353-.607.213-.668-.122-1.372-1.924-1.415-2.168-1.141-1.943-.14.08-.674 7.254-.316.37-.728.28-.607-.461-.322-.747.322-1.476.388-1.924.316-1.53.285-1.9.17-.632-.012-.042-.14.018-1.432 1.967-2.18 2.945-1.724 1.845-.413.164-.716-.37.066-.662.401-.589 2.386-3.036 1.439-1.882.929-1.086-.006-.158h-.055L4.138 18.56l-1.13.146-.485-.456.06-.746.231-.243 1.907-1.312Z';
const CHATGPT_MARK_PATH = 'M22.282 9.821a6 6 0 0 0-.516-4.91 6.05 6.05 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a6 6 0 0 0-3.998 2.9 6.05 6.05 0 0 0 .743 7.097 5.98 5.98 0 0 0 .51 4.911 6.05 6.05 0 0 0 6.515 2.9A6 6 0 0 0 13.26 24a6.06 6.06 0 0 0 5.772-4.206 6 6 0 0 0 3.997-2.9 6.06 6.06 0 0 0-.747-7.073M13.26 22.43a4.48 4.48 0 0 1-2.876-1.04l.141-.081 4.779-2.758a.8.8 0 0 0 .392-.681v-6.737l2.02 1.168a.07.07 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.494 4.494M3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085 4.783 2.759a.77.77 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646M2.34 7.896a4.5 4.5 0 0 1 2.366-1.973V11.6a.77.77 0 0 0 .388.677l5.815 3.354-2.02 1.168a.08.08 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855-5.833-3.387L15.119 7.2a.08.08 0 0 1 .071 0l4.83 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667m2.01-3.023-.141-.085-4.774-2.782a.78.78 0 0 0-.785 0L9.409 9.23V6.897a.07.07 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.8.8 0 0 0-.393.681zm1.097-2.365 2.602-1.5 2.607 1.5v2.999l-2.597 1.5-2.607-1.5Z';

function markDataUri(pathData, color) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="${color}" d="${pathData}"/></svg>`;
    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

const CLAUDE_MARK_DATA_URI = markDataUri(CLAUDE_MARK_PATH, CLAUDE_CORAL);
const CHATGPT_MARK_DATA_URI = markDataUri(CHATGPT_MARK_PATH, CHATGPT_GREEN);

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
    const accent = data.ogAccent || typeColor(data.type);
    const label = data.ogLabel || typeLabel(data.type);
    const providerStory = Boolean(data.ogProviderMarks);

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
        providerStory ? el('div', {
            style: {
                position: 'absolute',
                bottom: '-250px',
                left: '-260px',
                width: '650px',
                height: '650px',
                borderRadius: '650px',
                background: CLAUDE_CORAL,
                opacity: 0.065,
                display: 'flex',
            },
        }) : null,
        data.ogMonogram ? el('div', {
            style: {
                position: 'absolute',
                right: '54px',
                bottom: '24px',
                fontSize: '214px',
                lineHeight: 1,
                fontWeight: 700,
                letterSpacing: '-18px',
                color: accent,
                opacity: 0.075,
                display: 'flex',
            },
        }, data.ogMonogram) : null,
        // Accent vertical bar on the left
        providerStory ? el('div', {
            style: {
                position: 'absolute',
                top: '0',
                left: '0',
                width: '6px',
                height: '315px',
                background: CLAUDE_CORAL,
                display: 'flex',
            },
        }) : null,
        providerStory ? el('div', {
            style: {
                position: 'absolute',
                bottom: '0',
                left: '0',
                width: '6px',
                height: '315px',
                background: CHATGPT_GREEN,
                display: 'flex',
            },
        }) : el('div', {
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
            providerStory ? el('div', {
                style: {
                    display: 'flex',
                    alignItems: 'center',
                    gap: '12px',
                },
            },
                el('div', {
                    style: {
                        width: '48px',
                        height: '48px',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        border: `1px solid ${CLAUDE_CORAL}88`,
                        background: `${CLAUDE_CORAL}12`,
                    },
                }, el('img', { src: CLAUDE_MARK_DATA_URI, width: 27, height: 27, style: { display: 'flex' } })),
                el('div', {
                    style: {
                        width: '54px',
                        height: '1px',
                        background: `linear-gradient(90deg, ${CLAUDE_CORAL}99, ${CHATGPT_GREEN}99)`,
                        display: 'flex',
                    },
                }),
                el('div', {
                    style: {
                        width: '48px',
                        height: '48px',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        border: `1px solid ${CHATGPT_GREEN}88`,
                        background: `${CHATGPT_GREEN}12`,
                    },
                }, el('img', { src: CHATGPT_MARK_DATA_URI, width: 27, height: 27, style: { display: 'flex' } })),
            ) : el('div', {
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
            }, label)
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
            }, data.ogDomain || 'atelier.munyamakosa.com')
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
