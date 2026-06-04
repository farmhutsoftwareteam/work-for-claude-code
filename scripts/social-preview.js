'use strict';

/**
 * Generates a 1280×640 social preview PNG for the GitHub repo.
 * GitHub recommends 1280×640 (2:1). Same toolchain as og-image.js:
 * satori → SVG → resvg → PNG. Outputs to docs/social-preview.png so
 * the docs site can serve it too if anyone deep-links.
 *
 *   node scripts/social-preview.js
 *
 * Then upload to GitHub:
 *   gh api -X PATCH /repos/<owner>/<repo> -f description='...'  (one-time)
 *   gh api repos/<owner>/<repo>/social-preview \
 *       -X PATCH -F image=@docs/social-preview.png
 */

const fs = require('fs');
const path = require('path');
const satori = require('satori').default || require('satori');
const { Resvg } = require('@resvg/resvg-js');

const ROOT = path.resolve(__dirname, '..');
const FONTS = path.join(__dirname, 'fonts');

const FONT_BOLD = fs.readFileSync(path.join(FONTS, 'IBMPlexMono-Bold.ttf'));
const FONT_REG = fs.readFileSync(path.join(FONTS, 'IBMPlexMono-Regular.ttf'));

// Embed the 512px app icon as a data URI so satori can render it
const ICON_PATH = path.join(ROOT, 'Sources/Assets.xcassets/AppIcon.appiconset/app_icon_512.png');
const ICON_DATA_URI = 'data:image/png;base64,' + fs.readFileSync(ICON_PATH).toString('base64');

// Night Foundry palette — matches docs site + recipe OG cards
const C = {
    graphite: '#0d0d0f',
    graphiteSurface: '#15151a',
    border: '#26262d',
    ivory: '#f0ece4',
    ivoryMuted: '#a8a39a',
    ivoryFaint: '#6e6a64',
    blue: '#4a6fa5',
    blueBright: '#6b8fc7',
    accent: '#6b8fc7',
};

function el(type, props, ...children) {
    return { type, props: { ...props, children: children.flat().filter(Boolean) } };
}

function buildTree() {
    return el('div', {
        style: {
            width: '1280px',
            height: '640px',
            display: 'flex',
            flexDirection: 'row',
            position: 'relative',
            background: C.graphite,
            fontFamily: 'IBM Plex Mono',
            color: C.ivory,
            overflow: 'hidden',
        },
    },
        // Glow top-right
        el('div', {
            style: {
                position: 'absolute',
                top: '-220px',
                right: '-220px',
                width: '680px',
                height: '680px',
                borderRadius: '680px',
                background: C.blue,
                opacity: 0.10,
                display: 'flex',
            },
        }),
        // Accent vertical bar on the left
        el('div', {
            style: {
                position: 'absolute',
                top: '0',
                left: '0',
                width: '8px',
                height: '640px',
                background: C.accent,
                display: 'flex',
            },
        }),

        // LEFT COLUMN: text content
        el('div', {
            style: {
                display: 'flex',
                flexDirection: 'column',
                flex: '1 1 auto',
                padding: '64px 32px 64px 88px',
                justifyContent: 'space-between',
            },
        },
            // Top: nav strip with brand mark
            el('div', {
                style: { display: 'flex', alignItems: 'center', gap: '14px' },
            },
                el('div', {
                    style: {
                        fontSize: '13px',
                        fontWeight: 600,
                        color: C.accent,
                        letterSpacing: '2px',
                        textTransform: 'uppercase',
                        padding: '6px 12px',
                        border: `1px solid ${C.accent}55`,
                        borderRadius: '6px',
                        background: `${C.accent}15`,
                        display: 'flex',
                    },
                }, 'OPEN SOURCE · MIT'),
                el('div', {
                    style: {
                        fontSize: '13px',
                        fontWeight: 500,
                        color: C.ivoryMuted,
                        letterSpacing: '1px',
                        textTransform: 'uppercase',
                        display: 'flex',
                    },
                }, 'macOS · SwiftUI'),
            ),

            // Middle: huge title + tagline + feature row
            el('div', {
                style: { display: 'flex', flexDirection: 'column', gap: '20px' },
            },
                el('div', {
                    style: {
                        fontSize: '128px',
                        fontWeight: 700,
                        lineHeight: 0.95,
                        letterSpacing: '-6px',
                        color: C.ivory,
                        display: 'flex',
                    },
                }, 'Work'),
                el('div', {
                    style: {
                        fontSize: '30px',
                        fontWeight: 400,
                        lineHeight: 1.25,
                        letterSpacing: '-0.5px',
                        color: C.ivoryMuted,
                        maxWidth: '640px',
                        display: 'flex',
                    },
                }, 'The native macOS app for Claude Code.'),
                el('div', {
                    style: { display: 'flex', gap: '10px', marginTop: '8px' },
                },
                    ...['MCPs', 'Skills', 'Sessions', 'Usage'].map(label =>
                        el('div', {
                            style: {
                                fontSize: '15px',
                                fontWeight: 600,
                                color: C.ivory,
                                letterSpacing: '1px',
                                textTransform: 'uppercase',
                                padding: '8px 14px',
                                border: `1px solid ${C.border}`,
                                borderRadius: '6px',
                                background: C.graphiteSurface,
                                display: 'flex',
                            },
                        }, label),
                    ),
                ),
            ),

            // Bottom: github URL
            el('div', {
                style: {
                    display: 'flex',
                    alignItems: 'center',
                    fontSize: '20px',
                    color: C.ivoryMuted,
                    fontWeight: 500,
                    letterSpacing: '-0.3px',
                },
            }, 'github.com/farmhutsoftwareteam/work-for-claude-code')
        ),

        // RIGHT COLUMN: app icon
        el('div', {
            style: {
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                flex: '0 0 480px',
                padding: '64px',
            },
        },
            // Outer wrapper provides the soft drop-shadow halo via a
            // larger blue-tinted background; resvg doesn't render CSS
            // box-shadow reliably, so we fake it with a sibling div.
            el('div', {
                style: {
                    width: '380px',
                    height: '380px',
                    borderRadius: '90px',
                    background: `${C.blue}25`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                },
            },
                el('img', {
                    src: ICON_DATA_URI,
                    width: 340,
                    height: 340,
                    style: {
                        width: '340px',
                        height: '340px',
                    },
                })
            )
        ),
    );
}

async function main() {
    const tree = buildTree();
    const svg = await satori(tree, {
        width: 1280,
        height: 640,
        fonts: [
            { name: 'IBM Plex Mono', data: FONT_REG, weight: 400, style: 'normal' },
            { name: 'IBM Plex Mono', data: FONT_BOLD, weight: 700, style: 'normal' },
        ],
    });
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: 1280 } }).render().asPng();
    const outPath = path.join(ROOT, 'docs/social-preview.png');
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, png);
    console.log(`✓ ${outPath} (${(png.length / 1024).toFixed(1)} KB)`);
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
