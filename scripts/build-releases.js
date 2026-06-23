#!/usr/bin/env node
'use strict';

/**
 * Build a human-readable releases page from docs/appcast.xml.
 *
 *   node scripts/build-releases.js
 *
 * Produces docs/releases.html — each <item> in the appcast rendered as a
 * dated section with release notes.
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
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
}
function formatSize(bytes) {
    const b = parseInt(bytes, 10);
    if (!b) return '';
    return (b / (1024 * 1024)).toFixed(1) + ' MB';
}

// ─── HTML ───────────────────────────────────────────────────────────────────

function escHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function slugifyVersion(v) {
    // 1.0.12 → v1-0-12 (valid HTML id, stable shareable anchor)
    return 'v' + String(v).replace(/\./g, '-');
}

function renderRelease(item, isLatest) {
    const badge = isLatest
        ? `<span class="badge badge-latest">Latest</span>`
        : '';
    const sizeStr = formatSize(item.length);
    const anchor = slugifyVersion(item.version);
    return `
    <article class="release" id="${anchor}">
        <header class="release-header">
            <div class="release-title-row">
                <h2 class="release-version">
                    <a href="#${anchor}" class="anchor-link" aria-label="Permalink to v${escHtml(item.version)}" title="Copy link to this release">#</a>
                    v${escHtml(item.version)} ${badge}
                </h2>
                <span class="release-date">${escHtml(formatDate(item.pubDate))}</span>
            </div>
            <div class="release-meta">
                <a href="${escHtml(item.downloadUrl)}" class="download-link">
                    Download DMG${sizeStr ? ` <span class="size">(${sizeStr})</span>` : ''}
                </a>
                ${item.minSystem ? `<span class="min-system">macOS ${escHtml(item.minSystem)}+</span>` : ''}
            </div>
        </header>
        <div class="release-notes">
            ${item.notes}
        </div>
    </article>`;
}

function renderPage(items) {
    const latestVersion = items[0]?.version || '';
    const latestDate = items[0] ? formatDate(items[0].pubDate) : '';
    const releasesHtml = items.map((it, i) => renderRelease(it, i === 0)).join('');

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Releases | Atelier</title>
    <meta name="description" content="Every version of Atelier, what shipped when. Latest: v${escHtml(latestVersion)} (${escHtml(latestDate)}).">
    <link rel="canonical" href="${SITE_URL}/releases.html">
    <link rel="alternate" type="application/rss+xml" title="Atelier appcast" href="${SITE_URL}/appcast.xml">
    <meta property="og:type" content="website">
    <meta property="og:title" content="Releases | Atelier">
    <meta property="og:description" content="Every version of Atelier, what shipped when.">
    <meta property="og:url" content="${SITE_URL}/releases.html">
    <meta property="og:site_name" content="Atelier">
    <meta name="twitter:card" content="summary">

    <style>
    :root {
        --graphite: #111113;
        --graphite-surface: #18181b;
        --graphite-elevated: #1f1f23;
        --ivory: #f0ece4;
        --ivory-muted: rgba(240, 236, 228, 0.55);
        --ivory-faint: rgba(240, 236, 228, 0.12);
        --ivory-ghost: rgba(240, 236, 228, 0.06);
        --blue: #4a6fa5;
        --blue-bright: #5a8fd4;
        --border: rgba(240, 236, 228, 0.08);
        --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        --font-mono: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: var(--font-sans); background: var(--graphite); color: var(--ivory); line-height: 1.6; overflow-x: hidden; }
    a { color: var(--blue-bright); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .container { max-width: 960px; margin: 0 auto; padding: 0 24px; }
    .container-narrow { max-width: 720px; margin: 0 auto; padding: 0 24px; }

    /* Nav */
    nav.site-nav {
        position: fixed; top: 0; left: 0; right: 0; z-index: 100;
        padding: 16px 0;
        background: rgba(17, 17, 19, 0.85);
        backdrop-filter: blur(20px) saturate(1.4);
        -webkit-backdrop-filter: blur(20px) saturate(1.4);
        border-bottom: 1px solid var(--border);
    }
    nav.site-nav .container { display: flex; align-items: center; justify-content: space-between; }
    .nav-brand { display: flex; align-items: center; gap: 10px; }
    .nav-brand img { width: 28px; height: 28px; border-radius: 6px; }
    .nav-brand span { font-family: var(--font-mono); font-size: 15px; font-weight: 600; letter-spacing: -0.3px; color: var(--ivory); }
    .nav-links { display: flex; align-items: center; gap: 28px; }
    .nav-links a { font-size: 14px; font-weight: 450; color: var(--ivory-muted); transition: color 0.15s; }
    .nav-links a:hover { color: var(--ivory); text-decoration: none; }
    .nav-links a.active { color: var(--ivory); }
    .btn-download-nav {
        font-size: 13px; font-weight: 500; color: var(--ivory) !important;
        background: var(--blue); padding: 7px 16px; border-radius: 6px;
        transition: background 0.15s; text-decoration: none;
    }
    .btn-download-nav:hover { background: var(--blue-bright); text-decoration: none; }

    /* Page */
    .page-header { padding: 140px 0 40px; }
    h1.page-title {
        font-family: var(--font-mono);
        font-size: clamp(48px, 8vw, 72px);
        font-weight: 700; letter-spacing: -3px; line-height: 1.0; margin-bottom: 16px;
    }
    .page-subtitle {
        font-size: 18px; color: var(--ivory-muted);
        max-width: 520px; line-height: 1.6;
    }
    .section-label {
        font-family: var(--font-mono); font-size: 11px; font-weight: 500;
        text-transform: uppercase; letter-spacing: 1.5px;
        color: var(--blue-bright); margin-bottom: 16px;
    }

    /* Release cards */
    .releases { padding-bottom: 80px; }
    .release {
        background: var(--graphite-surface);
        border: 1px solid var(--border);
        border-radius: 12px;
        padding: 32px;
        margin-bottom: 20px;
    }
    .release-header { margin-bottom: 20px; }
    .release-title-row {
        display: flex; align-items: baseline; justify-content: space-between;
        gap: 16px; flex-wrap: wrap; margin-bottom: 10px;
    }
    .release-version {
        font-family: var(--font-mono);
        font-size: 24px; font-weight: 600; letter-spacing: -0.5px;
        color: var(--ivory);
        display: flex; align-items: baseline; gap: 10px;
    }
    .anchor-link {
        font-family: var(--font-mono);
        font-size: 18px; font-weight: 500;
        color: var(--ivory-faint);
        text-decoration: none;
        opacity: 0;
        transition: opacity 0.15s, color 0.15s;
    }
    .anchor-link:hover { color: var(--blue-bright); text-decoration: none; }
    .release:hover .anchor-link { opacity: 1; }
    /* Smooth-scroll target: offset so fixed nav doesn't obscure the heading */
    .release { scroll-margin-top: 80px; }
    /* Flash the targeted release briefly so users see where they landed */
    .release:target {
        animation: target-pulse 1.8s ease-out;
    }
    @keyframes target-pulse {
        0%   { box-shadow: 0 0 0 0 rgba(90, 143, 212, 0.55); }
        60%  { box-shadow: 0 0 0 8px rgba(90, 143, 212, 0.0); }
        100% { box-shadow: 0 0 0 0 rgba(90, 143, 212, 0.0); }
    }
    .release-date {
        font-size: 13px; color: var(--ivory-muted);
        font-family: var(--font-mono);
    }
    .release-meta {
        display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
        font-size: 13px;
    }
    .download-link {
        color: var(--blue-bright);
        font-weight: 500;
    }
    .download-link .size { color: var(--ivory-muted); font-family: var(--font-mono); font-size: 12px; }
    .min-system {
        color: var(--ivory-muted);
        font-family: var(--font-mono); font-size: 12px;
    }
    .badge {
        display: inline-block;
        font-family: var(--font-mono); font-size: 10px; font-weight: 600;
        text-transform: uppercase; letter-spacing: 1px;
        padding: 3px 8px; border-radius: 4px;
        vertical-align: middle;
        margin-left: 8px;
    }
    .badge-latest {
        background: rgba(74, 111, 165, 0.25);
        color: var(--blue-bright);
        border: 1px solid rgba(90, 143, 212, 0.4);
    }

    /* Release notes content (rendered from appcast CDATA) */
    .release-notes { color: var(--ivory); }
    .release-notes h3 {
        font-size: 16px; font-weight: 600;
        margin-bottom: 14px; letter-spacing: -0.2px;
    }
    .release-notes ul { list-style: none; padding: 0; }
    .release-notes li {
        position: relative;
        padding: 10px 0 10px 22px;
        border-bottom: 1px solid var(--ivory-ghost);
        font-size: 14px; line-height: 1.6;
        color: var(--ivory-muted);
    }
    .release-notes li:last-child { border-bottom: none; }
    .release-notes li::before {
        content: '›';
        position: absolute; left: 4px; top: 10px;
        color: var(--blue-bright);
        font-family: var(--font-mono); font-weight: 700;
    }
    .release-notes li b, .release-notes li strong { color: var(--ivory); font-weight: 600; }
    .release-notes p { margin-top: 12px; font-size: 14px; color: var(--ivory-muted); }
    .release-notes code {
        font-family: var(--font-mono); font-size: 12.5px;
        background: var(--ivory-ghost); padding: 1px 6px; border-radius: 4px;
        color: var(--ivory);
    }

    /* Footer */
    footer { padding: 40px 0; border-top: 1px solid var(--border); text-align: center; }
    footer p { font-size: 13px; color: rgba(240, 236, 228, 0.25); }

    @media (max-width: 768px) {
        .nav-links a:not(.btn-download-nav) { display: none; }
        .release { padding: 24px; }
    }
    </style>
</head>
<body>
    <nav class="site-nav">
        <div class="container">
            <a href="/" class="nav-brand">
                <img src="/icon-256.png" alt="Atelier">
                <span>Atelier</span>
            </a>
            <div class="nav-links">
                <a href="/">Home</a>
                <a href="/recipes/">Recipes</a>
                <a href="/releases.html" class="active">Releases</a>
                <a href="/Work.dmg" class="btn-download-nav">Download</a>
            </div>
        </div>
    </nav>

    <header class="page-header container">
        <div class="section-label">Changelog</div>
        <h1 class="page-title">Releases</h1>
        <p class="page-subtitle">Every version of Atelier, what shipped when. Subscribe via RSS: <a href="/appcast.xml">appcast.xml</a>.</p>
    </header>

    <main class="container releases">
        ${releasesHtml}
    </main>

    <footer>
        <div class="container">
            <p>Atelier · built by <a href="https://munyamakosa.com">Munya Makosa</a> · <a href="/appcast.xml">appcast.xml</a></p>
        </div>
    </footer>

    <script>
    // Click the "#" anchor to copy a shareable URL to the clipboard + flash
    // the release card. Browser still handles the URL fragment navigation.
    document.addEventListener('click', function (e) {
        var link = e.target.closest('a.anchor-link');
        if (!link) return;
        var href = link.getAttribute('href');
        if (!href || href[0] !== '#') return;
        var fullURL = location.origin + location.pathname + href;
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(fullURL).catch(function () {});
        }
        // Show a tiny "Copied!" toast
        var toast = document.createElement('div');
        toast.textContent = 'Link copied';
        toast.setAttribute('style', [
            'position:fixed','bottom:28px','left:50%','transform:translateX(-50%)',
            'background:rgba(90,143,212,0.95)','color:#fff','font-size:13px',
            'font-family:var(--font-mono, monospace)','padding:8px 14px',
            'border-radius:6px','z-index:9999','opacity:0',
            'transition:opacity 0.2s','pointer-events:none'
        ].join(';'));
        document.body.appendChild(toast);
        requestAnimationFrame(function () { toast.style.opacity = '1'; });
        setTimeout(function () { toast.style.opacity = '0'; }, 1400);
        setTimeout(function () { toast.remove(); }, 1800);
    });
    </script>
</body>
</html>
`;
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main() {
    if (!fs.existsSync(APPCAST)) {
        console.error(`✗ appcast not found at ${APPCAST}`);
        process.exit(1);
    }
    const xml = fs.readFileSync(APPCAST, 'utf8');
    const items = parseItems(xml);
    if (!items.length) {
        console.error('✗ no <item> entries in appcast');
        process.exit(1);
    }
    const html = renderPage(items);
    fs.writeFileSync(OUT, html);
    console.log(`✓ releases.html (${items.length} releases, latest v${items[0].version})`);
}

main();
