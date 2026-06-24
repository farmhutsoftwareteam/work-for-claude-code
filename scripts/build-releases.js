#!/usr/bin/env node
'use strict';

/**
 * Build a human-readable changelog from docs/appcast.xml.
 *
 *   node scripts/build-releases.js
 *
 * Produces docs/releases.html using the Atelier dovetail design - each
 * <item> in the appcast renders as one <article> with a 200px-wide date
 * column on the left and the release body on the right.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const APPCAST = path.join(ROOT, 'docs', 'appcast.xml');
const OUT = path.join(ROOT, 'docs', 'releases.html');
const SITE_URL = 'https://work.munyamakosa.com';

// ─── Parse appcast ──────────────────────────────────────────────────────────

function parseItems(xml) {
    const items = [];
    const itemRe = /<item>([\s\S]*?)<\/item>/g;
    let match;
    while ((match = itemRe.exec(xml)) !== null) {
        const body = match[1];
        items.push({
            title: extract(body, /<title>(.*?)<\/title>/),
            pubDate: extract(body, /<pubDate>(.*?)<\/pubDate>/),
            version: extract(body, /<sparkle:shortVersionString>(.*?)<\/sparkle:shortVersionString>/)
                  || extract(body, /<sparkle:version>(.*?)<\/sparkle:version>/),
            minSystem: extract(body, /<sparkle:minimumSystemVersion>(.*?)<\/sparkle:minimumSystemVersion>/),
            notes: extractCDATA(body, /<description>\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*<\/description>/)
                || extract(body, /<description>([\s\S]*?)<\/description>/),
            downloadUrl: extractAttr(body, /<enclosure[^>]*?\burl="([^"]+)"/),
            length: extractAttr(body, /<enclosure[^>]*?\blength="([^"]+)"/)
        });
    }
    return items;
}

function extract(s, re) {
    const m = s.match(re);
    return m ? m[1].trim() : '';
}
function extractCDATA(s, re) {
    const m = s.match(re);
    return m ? m[1].trim() : '';
}
function extractAttr(s, re) {
    const m = s.match(re);
    return m ? m[1] : '';
}

function formatDate(pubDate) {
    const d = new Date(pubDate);
    if (isNaN(d.getTime())) return pubDate || '';
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })
        .toLowerCase();
}

function formatDateShort(pubDate) {
    const d = new Date(pubDate);
    if (isNaN(d.getTime())) return pubDate || '';
    const y = d.getFullYear();
    const mon = d.toLocaleDateString('en-US', { month: 'short' }).toLowerCase();
    const day = String(d.getDate()).padStart(2, '0');
    return `${y} · ${mon} ${day}`;
}

function formatSize(bytes) {
    const b = parseInt(bytes, 10);
    if (!b) return '';
    return (b / (1024 * 1024)).toFixed(1) + ' MB';
}

function escHtml(s) {
    return String(s || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function versionAnchor(version) {
    return 'v' + String(version || '').replace(/\./g, '-').toLowerCase();
}

// ─── Render one article ─────────────────────────────────────────────────────

function renderRelease(item, isLatest, isFirst) {
    const anchor = versionAnchor(item.version);
    const dateShort = formatDateShort(item.pubDate);
    const tag = isLatest
        ? '<div style="display:inline-block;font-family:var(--mono);font-size:10px;letter-spacing:.08em;text-transform:uppercase;border:1px solid var(--line2);padding:3px 8px;margin-top:12px;">latest</div>'
        : isFirst
            ? '<div style="display:inline-block;font-family:var(--mono);font-size:10px;letter-spacing:.08em;text-transform:uppercase;border:1px solid var(--line2);padding:3px 8px;margin-top:12px;">first build</div>'
            : '';
    const lastBorder = isFirst ? '' : 'border-bottom:1px solid var(--line);';
    return `
    <article id="${anchor}" class="release-article" style="display:grid;grid-template-columns:200px 1fr;gap:40px;padding:38px 0;${lastBorder}">
      <div>
        <div style="font-family:var(--helv);font-weight:500;font-size:22px;letter-spacing:-.01em;">
          <a href="#${anchor}" style="color:var(--ink);text-decoration:none;">v${escHtml(item.version)}</a>
        </div>
        <div style="font-family:var(--mono);font-size:11px;color:var(--mute);margin-top:6px;">${escHtml(dateShort)}</div>
        ${tag}
        ${item.minSystem ? `<div style="font-family:var(--mono);font-size:10px;color:var(--mute);margin-top:10px;">macOS ${escHtml(item.minSystem)}+</div>` : ''}
      </div>
      <div class="release-body" style="font-family:var(--helv);font-size:16px;line-height:1.6;color:rgba(27,28,30,.82);">
        ${item.notes}
      </div>
    </article>`;
}

// ─── Page ───────────────────────────────────────────────────────────────────

function renderPage(items) {
    const latestVersion = items[0] ? items[0].version : '';
    const latestDate = items[0] ? formatDate(items[0].pubDate) : '';
    const releasesHtml = items.map((it, i) => renderRelease(it, i === 0, i === items.length - 1)).join('');

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Changelog - Atelier</title>
    <meta name="description" content="Every release of Atelier, dated and itemised. Latest: v${escHtml(latestVersion)} (${escHtml(latestDate)}).">
    <link rel="canonical" href="${SITE_URL}/releases.html">
    <link rel="alternate" type="application/rss+xml" title="Atelier appcast" href="${SITE_URL}/appcast.xml">

    <meta property="og:type" content="website">
    <meta property="og:title" content="Changelog - Atelier">
    <meta property="og:description" content="Every release of Atelier, dated and itemised.">
    <meta property="og:image" content="${SITE_URL}/og-image.png">
    <meta property="og:url" content="${SITE_URL}/releases.html">
    <meta property="og:site_name" content="Atelier">
    <meta name="twitter:card" content="summary_large_image">

    <link rel="icon" type="image/svg+xml" href="/atelier-mark.svg">
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
    <link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
    <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">

    <style>
        :root {
            --ink: #1b1c1e;
            --paper: #e9eae8;
            --paper2: #f3f4f2;
            --paper3: #dcdedb;
            --line: rgba(27, 28, 30, .18);
            --line2: rgba(27, 28, 30, .34);
            --mute: rgba(27, 28, 30, .54);
            --helv: 'Helvetica Neue', Helvetica, Arial, sans-serif;
            --mono: 'IBM Plex Mono', ui-monospace, monospace;
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; }
        body {
            background: var(--paper);
            color: var(--ink);
            -webkit-font-smoothing: antialiased;
            text-rendering: optimizeLegibility;
        }
        ::selection { background: var(--ink); color: var(--paper); }
        .nav-link { transition: color .12s ease; }
        .nav-link:hover { color: var(--ink) !important; }
        .nav-cta { transition: background .12s ease; }
        .nav-cta:hover { background: #000 !important; }
        .footer-link { transition: color .12s ease; }
        .footer-link:hover { color: var(--ink) !important; }

        .release-body h3 {
            font-family: var(--helv);
            font-weight: 500;
            font-size: 20px;
            line-height: 1.25;
            letter-spacing: -.015em;
            margin: 0 0 14px;
            color: var(--ink);
        }
        .release-body h4 {
            font-family: var(--mono);
            font-size: 11px;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: var(--mute);
            margin: 22px 0 10px;
        }
        .release-body ul { margin: 0 0 16px; padding-left: 18px; }
        .release-body li { margin-bottom: 8px; }
        .release-body p { margin: 0 0 14px; }
        .release-body code {
            font-family: var(--mono);
            font-size: 14px;
            background: var(--paper3);
            padding: 1px 5px;
            border-radius: 2px;
        }
        .release-body b, .release-body strong { font-weight: 500; color: var(--ink); }

        /* Mobile nav — full-screen paper overlay with editorial-sized links */
        .menu-toggle { display: none; }
        .menu-overlay { display: none; }
        .menu-link { transition: color .12s ease, transform .18s ease; }
        .menu-link:hover { color: var(--mute) !important; }
        body[data-menu="open"] { overflow: hidden; }
        body[data-menu="open"] .menu-overlay { display: flex !important; animation: menuFade .18s ease-out; }
        body[data-menu="open"] .menu-overlay .menu-link { animation: menuRise .42s cubic-bezier(.2,.7,.2,1) backwards; }
        body[data-menu="open"] .menu-overlay .menu-link:nth-child(1) { animation-delay: .04s; }
        body[data-menu="open"] .menu-overlay .menu-link:nth-child(2) { animation-delay: .09s; }
        body[data-menu="open"] .menu-overlay .menu-link:nth-child(3) { animation-delay: .14s; }
        body[data-menu="open"] .menu-overlay .menu-link:nth-child(4) { animation-delay: .19s; }
        @keyframes menuFade { from { opacity: 0; } to { opacity: 1; } }
        @keyframes menuRise { from { opacity: 0; transform: translateY(14px); } to { opacity: 1; transform: translateY(0); } }

        @media (max-width: 800px) {
            .responsive-padding { padding-left: 22px !important; padding-right: 22px !important; }
            .release-article { grid-template-columns: 1fr !important; gap: 14px !important; padding: 26px 0 !important; }
            .release-body h3 { font-size: 19px !important; }
            .release-body ul { padding-left: 18px !important; }
            .release-body li { font-size: 15.5px !important; line-height: 1.55 !important; }
            .release-body p { font-size: 15.5px !important; line-height: 1.6 !important; }
            h1 { font-size: 40px !important; }
            main.responsive-padding { padding-top: 48px !important; padding-bottom: 64px !important; }
            .nav-desktop { display: none !important; }
            .menu-toggle {
                display: inline-flex !important;
                align-items: center;
                gap: 8px;
                background: none;
                border: 1px solid var(--line2);
                font-family: var(--mono);
                font-size: 12.5px;
                letter-spacing: .06em;
                color: var(--ink);
                cursor: pointer;
                padding: 7px 13px;
                transition: background .12s ease, border-color .12s ease;
            }
            .menu-toggle:hover { background: var(--paper3); border-color: var(--ink); }
        }
    </style>
</head>
<body>

<svg width="0" height="0" style="position:absolute" aria-hidden="true">
    <symbol id="dt" viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="square" stroke-linejoin="miter">
        <rect x="7" y="7" width="50" height="50"/>
        <path d="M32 7 L32 24 L46 28 L46 36 L32 40 L32 57"/>
    </symbol>
</svg>

<div style="min-height:100vh;">

    <header style="position:sticky;top:0;z-index:40;background:rgba(233,234,232,.86);backdrop-filter:blur(8px);border-bottom:1px solid var(--line);">
        <div class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:14px 40px;display:flex;align-items:center;justify-content:space-between;">
            <a href="/" style="display:flex;align-items:center;gap:11px;text-decoration:none;color:var(--ink);">
                <svg viewBox="0 0 64 64" style="width:26px;height:26px;color:var(--ink);overflow:visible;"><use href="#dt"/></svg>
                <span style="font-family:var(--helv);font-weight:500;font-size:20px;letter-spacing:-.01em;">atelier</span>
            </a>
            <nav class="nav-desktop" style="display:flex;align-items:center;gap:30px;font-family:var(--mono);font-size:12.5px;letter-spacing:.02em;">
                <a href="/releases.html" style="color:var(--ink);text-decoration:none;">changelog</a>
                <a class="nav-link" href="/recipes/" style="color:var(--mute);text-decoration:none;">recipes</a>
                <a class="nav-link" href="/faq.html" style="color:var(--mute);text-decoration:none;">faq</a>
                <a class="nav-link" href="/pricing.html" style="color:var(--mute);text-decoration:none;">pricing</a>
                <a class="nav-cta" href="/#download" style="color:var(--paper);background:var(--ink);text-decoration:none;padding:8px 15px;letter-spacing:.04em;">download</a>
            </nav>
            <button class="menu-toggle" type="button" data-menu-toggle aria-label="Open menu" aria-expanded="false" aria-controls="site-menu">menu</button>
        </div>
    </header>

    <div class="menu-overlay" id="site-menu" data-menu-overlay aria-hidden="true" style="position:fixed;inset:0;z-index:100;background:var(--paper);flex-direction:column;">
        <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 24px;border-bottom:1px solid var(--line);">
            <a href="/" style="display:flex;align-items:center;gap:11px;text-decoration:none;color:var(--ink);">
                <svg viewBox="0 0 64 64" style="width:26px;height:26px;color:var(--ink);overflow:visible;"><use href="#dt"/></svg>
                <span style="font-family:var(--helv);font-weight:500;font-size:20px;letter-spacing:-.01em;">atelier</span>
            </a>
            <button type="button" data-menu-close aria-label="Close menu" style="background:none;border:1px solid var(--line2);font-family:var(--mono);font-size:12.5px;letter-spacing:.06em;color:var(--ink);cursor:pointer;padding:7px 13px;">close</button>
        </div>
        <nav style="flex:1;display:flex;flex-direction:column;justify-content:center;padding:0 28px;gap:22px;">
            <a class="menu-link" href="/releases.html" style="text-decoration:none;color:var(--mute);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">changelog</a>
            <a class="menu-link" href="/recipes/" style="text-decoration:none;color:var(--ink);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">recipes</a>
            <a class="menu-link" href="/faq.html" style="text-decoration:none;color:var(--ink);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">faq</a>
            <a class="menu-link" href="/pricing.html" style="text-decoration:none;color:var(--ink);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">pricing</a>
        </nav>
        <div style="padding:24px 28px 32px;border-top:1px solid var(--line);">
            <a href="/Work.dmg" style="display:flex;align-items:center;justify-content:center;gap:11px;background:var(--ink);color:var(--paper);text-decoration:none;padding:16px 22px;font-family:var(--helv);font-weight:500;font-size:17px;">
                <svg viewBox="0 0 64 64" style="width:20px;height:20px;color:var(--paper);overflow:visible;"><use href="#dt"/></svg>
                Download for Mac
            </a>
            <div style="font-family:var(--mono);font-size:11px;color:var(--mute);margin-top:12px;text-align:center;letter-spacing:.06em;">.dmg · macOS 15+ · free</div>
        </div>
    </div>

    <main class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:72px 40px 96px;">
        <div style="border-bottom:1px solid var(--line2);padding-bottom:34px;margin-bottom:8px;">
            <div style="font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mute);margin-bottom:16px;">release notes</div>
            <h1 style="font-family:var(--helv);font-weight:500;font-size:54px;line-height:1.02;letter-spacing:-.035em;margin:0;">Changelog</h1>
            <p style="font-family:var(--mono);font-size:12.5px;color:var(--mute);margin-top:16px;max-width:52ch;line-height:1.7;">Every release of Atelier, dated and itemised. Subscribe via RSS: <a href="/appcast.xml" style="color:var(--ink);">appcast.xml</a>.</p>
        </div>

        ${releasesHtml}
    </main>

    <footer style="border-top:1px solid var(--line);">
        <div class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:36px 40px;font-family:var(--mono);font-size:11px;color:var(--mute);display:flex;justify-content:space-between;flex-wrap:wrap;gap:16px;">
            <span>© mmxxvi atelier · a workshop for claude code</span>
            <span><a class="footer-link" href="/" style="color:var(--mute);text-decoration:none;">← home</a></span>
        </div>
    </footer>
</div>

<script>
    (function () {
        var body = document.body;
        var toggle = document.querySelector('[data-menu-toggle]');
        var closeBtn = document.querySelector('[data-menu-close]');
        var links = document.querySelectorAll('[data-menu-overlay] a');
        function openMenu() {
            body.setAttribute('data-menu', 'open');
            if (toggle) toggle.setAttribute('aria-expanded', 'true');
        }
        function closeMenu() {
            body.removeAttribute('data-menu');
            if (toggle) toggle.setAttribute('aria-expanded', 'false');
        }
        if (toggle) toggle.addEventListener('click', openMenu);
        if (closeBtn) closeBtn.addEventListener('click', closeMenu);
        links.forEach(function (a) { a.addEventListener('click', closeMenu); });
        document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeMenu(); });
    })();
</script>

</body>
</html>
`;
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main() {
    const xml = fs.readFileSync(APPCAST, 'utf8');
    const items = parseItems(xml);
    const html = renderPage(items);
    fs.writeFileSync(OUT, html);
    const latest = items[0] ? items[0].version : 'unknown';
    console.log(`✓ releases.html (${items.length} releases, latest v${latest})`);
}

main();
