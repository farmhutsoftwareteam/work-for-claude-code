#!/usr/bin/env node
'use strict';

/**
 * Build recipes from /recipes/*.md into /docs/recipes/*.html
 *
 *   cd scripts && npm install && npm run build
 *
 * Produces:
 *   docs/recipes/index.html          listing page
 *   docs/recipes/<slug>.html         one per markdown source
 *   updates docs/sitemap.xml         with recipe URLs
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');
const { marked } = require('marked');
const { generateOgImage } = require('./og-image');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'recipes');
const OUT = path.join(ROOT, 'docs', 'recipes');
const SITEMAP = path.join(ROOT, 'docs', 'sitemap.xml');
const SITE_URL = 'https://atelier.munyamakosa.com';
const CLAUDE_CORAL = '#D97757';
const CHATGPT_GREEN = '#10A37F';
const CLAUDE_MARK_PATH = 'm4.714 15.956 4.718-2.648.079-.23-.08-.128h-.23l-.79-.048-2.695-.073-2.337-.097-2.265-.122-.57-.121-.535-.704.055-.353.48-.321.685.06 1.518.104 2.277.157 1.651.098 2.447.255h.389l.054-.158-.133-.097-.103-.098-2.356-1.596-2.55-1.688-1.336-.972-.722-.491L2 6.223l-.158-1.008.656-.722.88.06.224.061.893.686 1.906 1.476 2.49 1.833.364.304.146-.104.018-.072-.164-.274-1.354-2.446-1.445-2.49-.644-1.032-.17-.619a3 3 0 0 1-.103-.729L6.287.133 6.7 0l.995.134.42.364.619 1.415L9.735 4.14l1.555 3.03.455.898.243.832.09.255h.159V9.01l.127-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.583.28.48.685-.067.444-.286 1.851-.558 2.903-.365 1.942h.213l.243-.242.983-1.306 1.652-2.064.728-.82.85-.904.547-.431h1.032l.759 1.129-.34 1.166-1.063 1.347-.88 1.142-1.263 1.7-.79 1.36.074.11.188-.02 2.853-.606 1.542-.28 1.84-.315.832.388.09.395-.327.807-1.967.486-2.307.462-3.436.813-.043.03.049.061 1.548.146.662.036h1.62l3.018.225.79.522.473.638-.08.485-1.213.62-1.64-.389-3.825-.91-1.31-.329h-.183v.11l1.093 1.068 2.003 1.81 2.508 2.33.127.578-.321.455-.34-.049-2.204-1.657-.85-.747-1.925-1.62h-.127v.17l.443.649 2.343 3.521.122 1.08-.17.353-.607.213-.668-.122-1.372-1.924-1.415-2.168-1.141-1.943-.14.08-.674 7.254-.316.37-.728.28-.607-.461-.322-.747.322-1.476.388-1.924.316-1.53.285-1.9.17-.632-.012-.042-.14.018-1.432 1.967-2.18 2.945-1.724 1.845-.413.164-.716-.37.066-.662.401-.589 2.386-3.036 1.439-1.882.929-1.086-.006-.158h-.055L4.138 18.56l-1.13.146-.485-.456.06-.746.231-.243 1.907-1.312Z';
const CHATGPT_MARK_PATH = 'M22.282 9.821a6 6 0 0 0-.516-4.91 6.05 6.05 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a6 6 0 0 0-3.998 2.9 6.05 6.05 0 0 0 .743 7.097 5.98 5.98 0 0 0 .51 4.911 6.05 6.05 0 0 0 6.515 2.9A6 6 0 0 0 13.26 24a6.06 6.06 0 0 0 5.772-4.206 6 6 0 0 0 3.997-2.9 6.06 6.06 0 0 0-.747-7.073M13.26 22.43a4.48 4.48 0 0 1-2.876-1.04l.141-.081 4.779-2.758a.8.8 0 0 0 .392-.681v-6.737l2.02 1.168a.07.07 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.494 4.494M3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085 4.783 2.759a.77.77 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646M2.34 7.896a4.5 4.5 0 0 1 2.366-1.973V11.6a.77.77 0 0 0 .388.677l5.815 3.354-2.02 1.168a.08.08 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855-5.833-3.387L15.119 7.2a.08.08 0 0 1 .071 0l4.83 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667m2.01-3.023-.141-.085-4.774-2.782a.78.78 0 0 0-.785 0L9.409 9.23V6.897a.07.07 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.8.8 0 0 0-.393.681zm1.097-2.365 2.602-1.5 2.607 1.5v2.999l-2.597 1.5-2.607-1.5Z';

// ─── Helpers ────────────────────────────────────────────────────────────────

function escHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function providerMark(pathData, label, size = 24) {
    return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" role="img" aria-label="${escHtml(label)}"><path fill="currentColor" d="${pathData}"/></svg>`;
}

function renderProviderSignal(data) {
    if (!data.providerStory) return '';
    return `<div class="provider-signal" aria-label="Claude and ChatGPT">
        <span class="provider-mark provider-mark-claude" title="Claude">${providerMark(CLAUDE_MARK_PATH, 'Claude', 27)}</span>
        <span class="provider-bridge" aria-hidden="true"><i></i></span>
        <span class="provider-mark provider-mark-chatgpt" title="ChatGPT">${providerMark(CHATGPT_MARK_PATH, 'ChatGPT', 27)}</span>
    </div>`;
}

function formatDate(d) {
    const date = new Date(d);
    return date.toLocaleDateString('en-US', {
        year: 'numeric', month: 'long', day: 'numeric'
    });
}

function typeLabel(type) {
    const m = {
        skill: 'SKILL',
        mcp: 'MCP',
        hook: 'HOOK',
        command: 'COMMAND',
        'claude-md': 'CLAUDE.MD',
        workflow: 'WORKFLOW',
        announcement: 'ANNOUNCEMENT'
    };
    return m[type] || type.toUpperCase();
}

function typeColor(type) {
    const m = {
        skill: '#a78bfa',       // purple
        mcp: '#4a6fa5',         // brand blue
        hook: '#f59e0b',        // amber
        command: '#10b981',     // emerald
        'claude-md': '#ec4899', // pink
        workflow: '#06b6d4',    // cyan
        announcement: '#1b1c1e' // graphite - brand-aligned for launch posts
    };
    return m[type] || '#5a8fd4';
}

function validate(data, filename) {
    const required = ['title', 'type', 'description', 'date'];
    for (const k of required) {
        if (!(k in data)) throw new Error(`${filename}: missing frontmatter "${k}"`);
    }
    const validTypes = ['skill', 'mcp', 'hook', 'command', 'claude-md', 'workflow', 'announcement'];
    if (!validTypes.includes(data.type)) {
        throw new Error(`${filename}: type "${data.type}" is not one of ${validTypes.join(', ')}`);
    }
    // install block is optional - recipes can be pure tutorials (e.g. workflows)
    if (data.install) {
        for (const k of ['label', 'content']) {
            if (!data.install[k]) throw new Error(`${filename}: install.${k} is required when install is provided`);
        }
    }
}

// ─── Shared head + nav + CSS ────────────────────────────────────────────────

const SHARED_STYLE = `
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
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    html { font-size: 16px; -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; scroll-behavior: smooth; }
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

    /* Footer */
    footer { padding: 40px 0; border-top: 1px solid var(--border); text-align: center; margin-top: 80px; }
    footer p { font-size: 13px; color: rgba(240, 236, 228, 0.25); }

    /* Section labels */
    .section-label {
        font-family: var(--font-mono); font-size: 11px; font-weight: 500;
        text-transform: uppercase; letter-spacing: 1.5px;
        color: var(--blue-bright); margin-bottom: 16px;
    }

    @media (max-width: 768px) {
        .nav-links a:not(.btn-download-nav) { display: none; }
    }
`;

function renderNav(active = '', base = '../') {
    // `base` is the path prefix that walks up to the site root from the current page.
    //   - For /recipes/index.html  → base = '../'
    //   - For /recipes/slug.html   → base = '../'
    const links = [
        [`${base}`, 'Home', 'home'],
        [`${base}recipes/`, 'Recipes', 'recipes'],
        [`${base}releases.html`, 'Releases', 'releases'],
        [`${base}#faq`, 'FAQ', 'faq'],
    ];
    return `<nav class="site-nav">
        <div class="container">
            <a href="${base}" class="nav-brand">
                <img src="${base}icon-256.png" alt="Atelier icon">
                <span>Atelier</span>
            </a>
            <div class="nav-links">
                ${links.map(([href, label, id]) =>
                    `<a href="${href}"${id === active ? ' class="active"' : ''}>${label}</a>`
                ).join('\n                ')}
                <a href="${base}Work.dmg" class="btn-download-nav">Download</a>
            </div>
        </div>
    </nav>`;
}

function renderFooter() {
    return `<footer>
        <div class="container">
            <p>Built by <a href="https://munyamakosa.com" target="_blank" rel="noopener">Munya Makosa</a></p>
        </div>
    </footer>`;
}

// ─── Detail template ────────────────────────────────────────────────────────

const DETAIL_STYLE = `
    .article-header {
        padding: 140px 0 40px;
    }
    .back-link {
        display: inline-flex; align-items: center; gap: 6px;
        font-size: 13px; color: var(--ivory-muted);
        margin-bottom: 32px; text-decoration: none;
    }
    .back-link:hover { color: var(--ivory); text-decoration: none; }
    .article-meta {
        display: flex; align-items: center; gap: 12px;
        margin-bottom: 20px;
        font-size: 12px;
    }
    .type-badge {
        display: inline-block;
        font-family: var(--font-mono); font-size: 10px; font-weight: 700;
        text-transform: uppercase; letter-spacing: 1.0px;
        padding: 4px 8px; border-radius: 4px;
    }
    .meta-dot { color: rgba(240, 236, 228, 0.25); }
    .meta-item { color: var(--ivory-muted); }
    h1.article-title {
        font-size: clamp(32px, 5vw, 44px);
        font-weight: 700; letter-spacing: -1.6px;
        line-height: 1.15;
        margin-bottom: 14px;
    }
    .article-description {
        font-size: 18px; color: var(--ivory-muted);
        line-height: 1.55;
        max-width: 640px;
    }

    /* Article body */
    .article-body {
        padding: 40px 0;
        font-size: 16px;
        line-height: 1.75;
        color: rgba(240, 236, 228, 0.85);
    }
    .article-body h2 {
        font-size: 22px; font-weight: 600; letter-spacing: -0.6px;
        margin: 48px 0 16px;
        color: var(--ivory);
    }
    .article-body h3 {
        font-size: 18px; font-weight: 600; letter-spacing: -0.4px;
        margin: 32px 0 12px;
        color: var(--ivory);
    }
    .article-body h2:first-child, .article-body h3:first-child { margin-top: 0; }
    .article-body p { margin-bottom: 18px; }
    .article-body ul, .article-body ol { margin: 0 0 18px 24px; }
    .article-body li { margin-bottom: 6px; }
    .article-body strong { color: var(--ivory); font-weight: 600; }
    .article-body code {
        font-family: var(--font-mono); font-size: 13.5px;
        background: rgba(240, 236, 228, 0.07);
        padding: 2px 6px; border-radius: 4px;
        color: #f0b99c;
    }
    .article-body pre {
        background: var(--graphite-surface);
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 16px;
        overflow-x: auto;
        margin-bottom: 18px;
    }
    .article-body pre code {
        background: none; padding: 0; color: var(--ivory);
        font-size: 13px; line-height: 1.6;
    }
    .article-body blockquote {
        border-left: 3px solid var(--blue);
        padding-left: 16px;
        margin: 20px 0 20px 0;
        color: var(--ivory-muted);
        font-style: italic;
    }
    .article-body hr {
        border: none;
        border-top: 1px solid var(--border);
        margin: 40px 0;
    }
    .article-body img {
        display: block;
        max-width: 100%;
        height: auto;
        margin: 32px auto;
        border-radius: 12px;
        border: 1px solid var(--border);
        box-shadow: 0 12px 36px rgba(0, 0, 0, 0.4);
    }
    .article-body table {
        width: 100%;
        margin: 24px 0;
        border-collapse: separate;
        border-spacing: 0;
        background: var(--graphite-surface);
        border: 1px solid var(--border);
        border-radius: 10px;
        overflow: hidden;
        font-size: 15px;
    }
    .article-body th {
        text-align: left;
        font-family: var(--font-mono);
        font-size: 11px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 1.2px;
        color: var(--blue-bright);
        padding: 14px 18px;
        background: rgba(74, 111, 165, 0.06);
        border-bottom: 1px solid var(--border);
    }
    .article-body td {
        padding: 14px 18px;
        color: var(--ivory-muted);
        border-bottom: 1px solid var(--border);
        vertical-align: top;
    }
    .article-body tr:last-child td { border-bottom: none; }
    .article-body td:first-child { color: var(--ivory); }
    .article-body td code, .article-body th code {
        background: rgba(74, 111, 165, 0.12);
        color: var(--ivory);
    }

    /* Install card */
    .install-card {
        background: var(--graphite-surface);
        border: 1px solid rgba(74, 111, 165, 0.3);
        border-radius: 12px;
        margin: 36px 0;
        overflow: hidden;
        box-shadow: 0 0 0 1px rgba(74, 111, 165, 0.1), 0 8px 24px rgba(0, 0, 0, 0.2);
    }
    .install-header {
        display: flex; align-items: center; justify-content: space-between;
        padding: 14px 18px;
        background: rgba(74, 111, 165, 0.08);
        border-bottom: 1px solid var(--border);
        gap: 12px;
        flex-wrap: wrap;
    }
    .install-label {
        font-size: 12px; font-weight: 500;
        color: var(--ivory);
        font-family: var(--font-mono);
    }
    .install-label-eyebrow {
        display: block;
        font-size: 10px;
        font-weight: 600;
        color: var(--blue-bright);
        font-family: var(--font-mono);
        text-transform: uppercase;
        letter-spacing: 1px;
        margin-bottom: 4px;
    }
    .copy-btn {
        display: inline-flex; align-items: center; gap: 6px;
        padding: 6px 12px;
        background: var(--blue);
        color: var(--ivory);
        border: none; border-radius: 6px;
        font-size: 12px; font-weight: 500; cursor: pointer;
        font-family: var(--font-sans);
        transition: background 0.15s;
    }
    .copy-btn:hover { background: var(--blue-bright); }
    .copy-btn svg { width: 12px; height: 12px; }
    .install-body {
        padding: 16px 18px;
        background: #0a0a0c;
        overflow-x: auto;
    }
    .install-body pre {
        margin: 0;
        font-family: var(--font-mono);
        font-size: 12.5px;
        line-height: 1.65;
        color: #d4d4d4;
        white-space: pre;
    }

    /* Related */
    .related {
        margin-top: 64px;
        padding-top: 32px;
        border-top: 1px solid var(--border);
    }
    .related h3 {
        font-size: 12px; font-family: var(--font-mono);
        text-transform: uppercase; letter-spacing: 1.5px;
        color: var(--ivory-muted); margin-bottom: 14px; font-weight: 500;
    }
    .related-list a {
        display: block;
        padding: 12px 0;
        border-bottom: 1px solid var(--border);
        color: var(--ivory);
        font-size: 14px;
        text-decoration: none;
    }
    .related-list a:last-child { border-bottom: none; }
    .related-list a:hover { color: var(--blue-bright); text-decoration: none; }
    .related-list a .related-type {
        display: inline-block;
        font-family: var(--font-mono); font-size: 9px;
        text-transform: uppercase; letter-spacing: 1px;
        color: var(--ivory-muted); margin-right: 8px;
    }
`;

function renderDetailPage(data) {
    const pageUrl = `${SITE_URL}/recipes/${data.slug}.html`;

    // SEO overrides: invisible to readers, used only in <head> / structured data.
    const seoTitle = data.seoTitle || data.title;
    const metaDesc = data.metaDescription || data.description;
    const ogImage = data.ogImage
        ? `${SITE_URL}/recipes/${data.ogImage}`
        : `${SITE_URL}/recipes/og/${data.slug}.png`;
    const ogImageAlt = data.imageAlt || seoTitle;
    const ogImageWidth = data.ogImageWidth || 1200;
    const ogImageHeight = data.ogImageHeight || 630;
    const datePublished = new Date(data.date).toISOString();
    const dateModified = new Date(data.updated || data.date).toISOString();
    const wordCount = data.bodyHtml
        ? data.bodyHtml.replace(/<[^>]*>/g, ' ').trim().split(/\s+/).length
        : undefined;
    const keywords = Array.isArray(data.keywords) && data.keywords.length
        ? data.keywords
        : (data.tags || []);
    const dateShort = formatDateShort(data.date);

    const nextLink = data.next
        ? `<a class="next-link" href="${escHtml(data.next.slug)}.html" style="display:flex;align-items:center;justify-content:space-between;text-decoration:none;color:var(--ink);border-top:1px solid var(--line);margin-top:48px;padding-top:28px;gap:24px;">
            <span style="font-family:var(--mono);font-size:11.5px;color:var(--mute);">next · ${escHtml(data.next.type)}</span>
            <span style="font-family:var(--helv);font-weight:500;font-size:20px;letter-spacing:-.015em;text-align:right;">${escHtml(data.next.title)} →</span>
        </a>`
        : '';

    const installCard = data.install
        ? `<div style="margin:40px 0;border:1px solid var(--line2);background:var(--paper2);">
            <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:1px solid var(--line);font-family:var(--mono);font-size:11.5px;">
                <div>
                    <span style="color:var(--mute);letter-spacing:.1em;text-transform:uppercase;margin-right:10px;">install</span>
                    <span style="color:var(--ink);">${escHtml(data.install.label)}</span>
                </div>
                <button class="copy-btn" data-copy style="font-family:var(--mono);font-size:11.5px;border:1px solid var(--line2);background:var(--paper);color:var(--ink);padding:5px 10px;cursor:pointer;">Copy</button>
            </div>
            <pre style="font-family:var(--mono);font-size:13px;line-height:1.7;margin:0;padding:18px 20px;overflow-x:auto;white-space:pre;color:rgba(27,28,30,.85);"><code>${escHtml(data.install.content)}</code></pre>
        </div>`
        : '';

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escHtml(seoTitle)} | Atelier</title>
    <meta name="description" content="${escHtml(metaDesc)}">
    <meta name="author" content="Munya Makosa">
    <meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1">
    ${keywords.length ? `<meta name="keywords" content="${escHtml(keywords.join(', '))}">` : ''}
    <link rel="canonical" href="${pageUrl}">
    <link rel="alternate" type="application/rss+xml" title="Atelier Recipes" href="${SITE_URL}/recipes/feed.xml">

    <meta property="og:type" content="article">
    <meta property="og:locale" content="en_US">
    <meta property="og:title" content="${escHtml(seoTitle)}">
    <meta property="og:description" content="${escHtml(metaDesc)}">
    <meta property="og:url" content="${pageUrl}">
    <meta property="og:image" content="${ogImage}">
    <meta property="og:image:alt" content="${escHtml(ogImageAlt)}">
    <meta property="og:image:width" content="${ogImageWidth}">
    <meta property="og:image:height" content="${ogImageHeight}">
    <meta property="og:site_name" content="Atelier">
    <meta property="article:published_time" content="${datePublished}">
    <meta property="article:modified_time" content="${dateModified}">
    <meta property="article:author" content="https://munyamakosa.com">
    ${(data.tags || []).map(t => `<meta property="article:tag" content="${escHtml(t)}">`).join('\n    ')}

    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:site" content="@munyamakosa">
    <meta name="twitter:creator" content="@munyamakosa">
    <meta name="twitter:title" content="${escHtml(seoTitle)}">
    <meta name="twitter:description" content="${escHtml(metaDesc)}">
    <meta name="twitter:image" content="${ogImage}">
    <meta name="twitter:image:alt" content="${escHtml(ogImageAlt)}">

    <script type="application/ld+json">
    {
        "@context": "https://schema.org",
        "@type": "TechArticle",
        "headline": ${JSON.stringify(seoTitle)},
        "name": ${JSON.stringify(data.title)},
        "description": ${JSON.stringify(metaDesc)},
        "datePublished": "${datePublished}",
        "dateModified": "${dateModified}",
        "url": "${pageUrl}",
        "mainEntityOfPage": { "@type": "WebPage", "@id": "${pageUrl}" },
        "image": {
            "@type": "ImageObject",
            "url": "${ogImage}",
            "width": ${ogImageWidth},
            "height": ${ogImageHeight}
        },
        "author": {
            "@type": "Person",
            "name": "Munya Makosa",
            "url": "https://munyamakosa.com"
        },
        "publisher": {
            "@type": "Organization",
            "name": "Atelier",
            "url": "${SITE_URL}",
            "logo": {
                "@type": "ImageObject",
                "url": "${SITE_URL}/icon-256.png",
                "width": 256,
                "height": 256
            }
        }${wordCount ? `,
        "wordCount": ${wordCount}` : ''}${keywords.length ? `,
        "keywords": ${JSON.stringify(keywords.join(', '))}` : ''}${data.readTime ? `,
        "timeRequired": "PT${data.readTime}M"` : ''}
    }
    </script>

    <script type="application/ld+json">
    {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            { "@type": "ListItem", "position": 1, "name": "Atelier", "item": "${SITE_URL}/" },
            { "@type": "ListItem", "position": 2, "name": "Recipes", "item": "${SITE_URL}/recipes/" },
            { "@type": "ListItem", "position": 3, "name": ${JSON.stringify(data.title)}, "item": "${pageUrl}" }
        ]
    }
    </script>

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
        .crumb-link { transition: color .12s ease; }
        .crumb-link:hover { color: var(--ink) !important; }
        .btn-primary { transition: background .12s ease; }
        .btn-primary:hover { background: #000 !important; }
        .copy-btn { transition: background .12s ease; }
        .copy-btn:hover { background: var(--paper3); }
        .next-link { transition: color .12s ease; }
        .next-link:hover { color: var(--mute); }
        .footer-link { transition: color .12s ease; }
        .footer-link:hover { color: var(--ink) !important; }

        .article-masthead-provider {
            position: relative;
            margin: 0 -30px 48px;
            padding: 28px 30px 0;
            overflow: hidden;
            border: 1px solid var(--line);
            background:
                radial-gradient(circle at 0 0, rgba(217, 119, 87, .13), transparent 37%),
                radial-gradient(circle at 100% 0, rgba(16, 163, 127, .11), transparent 39%),
                rgba(243, 244, 242, .5);
        }
        .article-masthead-provider::before {
            content: '';
            position: absolute;
            inset: 0 0 auto;
            height: 3px;
            background: linear-gradient(90deg, ${CLAUDE_CORAL} 0 46%, var(--paper) 46% 54%, ${CHATGPT_GREEN} 54% 100%);
        }
        .article-masthead-provider .article-meta-row { margin-bottom: 0 !important; }
        .provider-signal {
            display: flex;
            align-items: center;
            width: 100%;
            gap: 12px;
            margin-bottom: 24px;
        }
        .provider-mark {
            width: 46px;
            height: 46px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            border: 1px solid currentColor;
            background: var(--paper2);
        }
        .provider-mark-claude { color: ${CLAUDE_CORAL}; }
        .provider-mark-chatgpt { color: ${CHATGPT_GREEN}; }
        .provider-bridge {
            position: relative;
            height: 1px;
            flex: 1;
            background: linear-gradient(90deg, rgba(217,119,87,.42), var(--line), rgba(16,163,127,.42));
        }
        .provider-bridge i {
            position: absolute;
            top: 50%;
            left: 50%;
            width: 7px;
            height: 7px;
            border: 1px solid var(--line2);
            background: var(--paper);
            transform: translate(-50%, -50%) rotate(45deg);
        }

        /* Article body typography - matches the design's paragraph rhythm */
        .article-body p {
            font-family: var(--helv);
            font-size: 18px;
            line-height: 1.62;
            margin: 0 0 22px;
            color: rgba(27, 28, 30, .9);
        }
        .article-body h2 {
            font-family: var(--helv);
            font-weight: 500;
            font-size: 27px;
            letter-spacing: -.02em;
            line-height: 1.15;
            margin: 44px 0 16px;
        }
        .article-body h3 {
            font-family: var(--helv);
            font-weight: 500;
            font-size: 21px;
            letter-spacing: -.015em;
            margin: 32px 0 12px;
        }
        .article-body h4 {
            font-family: var(--mono);
            font-size: 11.5px;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: var(--mute);
            margin: 28px 0 12px;
        }
        .article-body blockquote {
            font-family: var(--helv);
            font-weight: 500;
            font-size: 26px;
            line-height: 1.2;
            letter-spacing: -.02em;
            margin: 36px 0;
            padding-left: 22px;
            border-left: 3px solid var(--ink);
            max-width: 28ch;
            color: var(--ink);
        }
        .article-body ul, .article-body ol {
            font-family: var(--helv);
            font-size: 17px;
            line-height: 1.6;
            color: rgba(27, 28, 30, .9);
            margin: 0 0 22px;
            padding-left: 20px;
        }
        .article-body li { margin-bottom: 10px; }
        .article-body code {
            font-family: var(--mono);
            font-size: 14px;
            background: var(--paper3);
            padding: 1px 6px;
            border-radius: 2px;
        }
        .article-body pre {
            font-family: var(--mono);
            font-size: 13px;
            line-height: 1.7;
            background: var(--paper2);
            border: 1px solid var(--line2);
            padding: 20px 22px;
            margin: 0 0 28px;
            overflow-x: auto;
            white-space: pre;
            color: rgba(27, 28, 30, .85);
        }
        .article-body pre code {
            background: none;
            padding: 0;
            border-radius: 0;
            font-size: 13px;
        }
        .article-body a {
            color: var(--ink);
            text-decoration: underline;
            text-decoration-color: var(--line2);
            text-underline-offset: 3px;
        }
        .article-body a:hover { text-decoration-color: var(--ink); }
        .article-body strong, .article-body b { font-weight: 500; color: var(--ink); }
        .article-body hr {
            border: none;
            border-top: 1px solid var(--line);
            margin: 36px 0;
        }
        .article-body img {
            max-width: 100%;
            height: auto;
            border: 1px solid var(--line);
            margin: 24px 0;
        }

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
            .article-title { font-size: 36px !important; line-height: 1.04 !important; }
            .article-subtitle { font-size: 18px !important; }
            .article-masthead-provider { margin: 0 0 38px; padding: 22px 18px 0; }
            .provider-signal { margin-bottom: 20px; }
            .provider-mark { width: 40px; height: 40px; }
            main.responsive-padding { padding-top: 18px !important; padding-bottom: 64px !important; }
            .cta-card { flex-direction: column !important; align-items: flex-start !important; padding: 26px !important; margin-top: 40px !important; gap: 18px !important; }
            .next-link { flex-direction: column !important; align-items: flex-start !important; gap: 8px !important; }
            .next-link > span:last-child { text-align: left !important; font-size: 17px !important; }
            /* Article body: tighter type + padding so prose actually breathes. */
            .article-body h1.article-title { max-width: none !important; }
            .article-body p { font-size: 17px !important; line-height: 1.6 !important; }
            .article-body h2 { font-size: 24px !important; margin-top: 36px !important; }
            .article-body h3 { font-size: 19px !important; margin-top: 28px !important; }
            .article-body blockquote { font-size: 20px !important; margin: 28px 0 !important; padding-left: 16px !important; max-width: none !important; }
            .article-body pre { padding: 16px !important; font-size: 12.5px !important; }
            .article-meta-row { flex-wrap: wrap !important; gap: 10px 14px !important; }
            .article-meta-row > span:last-child { margin-left: 0 !important; }
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
                <a class="nav-link" href="/releases.html" style="color:var(--mute);text-decoration:none;">changelog</a>
                <a href="/recipes/" style="color:var(--ink);text-decoration:none;">recipes</a>
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
            <a class="menu-link" href="/releases.html" style="text-decoration:none;color:var(--ink);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">changelog</a>
            <a class="menu-link" href="/recipes/" style="text-decoration:none;color:var(--mute);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">recipes</a>
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

    <main class="responsive-padding" style="max-width:920px;margin:0 auto;padding:28px 40px 96px;">

        <!-- breadcrumb -->
        <div style="font-family:var(--mono);font-size:11.5px;color:var(--mute);padding:18px 0 36px;">
            <a class="crumb-link" href="/recipes/" style="color:var(--mute);text-decoration:none;">recipes</a> <span style="margin:0 8px;">/</span> ${escHtml(data.type)}
        </div>

        <!-- article masthead -->
        <article class="article-body">
        <header class="article-masthead${data.providerStory ? ' article-masthead-provider' : ''}">
${data.providerStory ? `            ${renderProviderSignal(data)}
` : ''}
            <div style="display:flex;align-items:center;gap:12px;font-family:var(--mono);font-size:11.5px;color:var(--mute);margin-bottom:22px;">
                <span style="border:1px solid var(--line2);padding:3px 9px;letter-spacing:.06em;">${escHtml(data.type)}</span>
                ${data.readTime ? `<span>${escHtml(data.readTime)} min read</span>` : ''}
            </div>
            <h1 class="article-title" style="font-family:var(--helv);font-weight:500;font-size:52px;line-height:1.02;letter-spacing:-.035em;margin:0 0 22px;max-width:20ch;">${escHtml(data.title)}</h1>
            <p class="article-subtitle" style="font-family:var(--helv);font-size:21px;line-height:1.45;color:rgba(27,28,30,.78);margin:0 0 30px;max-width:46ch;">${escHtml(data.description)}</p>
            <div class="article-meta-row" style="display:flex;align-items:center;gap:16px;font-family:var(--mono);font-size:12px;color:var(--mute);border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:16px 0;margin-bottom:48px;flex-wrap:wrap;">
                <svg viewBox="0 0 64 64" style="width:20px;height:20px;color:var(--ink);overflow:visible;"><use href="#dt"/></svg>
                <span style="color:var(--ink);">the atelier workshop</span>
                <span style="margin-left:auto;">${escHtml(dateShort)}</span>
            </div>
        </header>

            ${data.bodyHtml}
${installCard ? `
            ${installCard}
` : ''}
        </article>

        <!-- CTA -->
        <div class="cta-card" style="margin-top:56px;border:1px solid var(--line2);background:var(--paper2);padding:34px;display:flex;align-items:center;justify-content:space-between;gap:28px;flex-wrap:wrap;">
            <div>
                <h3 style="font-family:var(--helv);font-weight:500;font-size:24px;letter-spacing:-.02em;margin:0 0 6px;">Try this in Atelier</h3>
                <p style="font-family:var(--mono);font-size:12.5px;color:var(--mute);margin:0;">Six live sessions in one window. Free for macOS 15+.</p>
            </div>
            <a class="btn-primary" href="/Work.dmg" style="display:inline-flex;align-items:center;gap:11px;background:var(--ink);color:var(--paper);text-decoration:none;padding:14px 22px;font-family:var(--helv);font-weight:500;font-size:16px;">
                <svg viewBox="0 0 64 64" style="width:19px;height:19px;color:var(--paper);overflow:visible;"><use href="#dt"/></svg>
                Download for Mac
            </a>
        </div>

        ${nextLink}

    </main>

    <footer style="border-top:1px solid var(--line);">
        <div class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:36px 40px;font-family:var(--mono);font-size:11px;color:var(--mute);display:flex;justify-content:space-between;flex-wrap:wrap;gap:16px;">
            <span>© mmxxvi atelier · a workshop for serious model work</span>
            <span><a class="footer-link" href="/recipes/" style="color:var(--mute);text-decoration:none;">← all recipes</a></span>
        </div>
    </footer>
</div>

<script>
    (function () {
        document.querySelectorAll('[data-copy]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var pre = btn.closest('div').parentElement.querySelector('pre code');
                if (!pre) return;
                var code = pre.innerText;
                (async function () {
                    try {
                        await navigator.clipboard.writeText(code);
                        var original = btn.textContent;
                        btn.textContent = 'Copied ✓';
                        setTimeout(function () { btn.textContent = original; }, 1600);
                    } catch (e) {}
                })();
            });
        });
    })();
    (function () {
        var body = document.body;
        var toggle = document.querySelector('[data-menu-toggle]');
        var closeBtn = document.querySelector('[data-menu-close]');
        var links = document.querySelectorAll('[data-menu-overlay] a');
        function openMenu() { body.setAttribute('data-menu', 'open'); if (toggle) toggle.setAttribute('aria-expanded', 'true'); }
        function closeMenu() { body.removeAttribute('data-menu'); if (toggle) toggle.setAttribute('aria-expanded', 'false'); }
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

// ─── Listing template (Atelier dovetail design, light palette) ──────────────

function formatDateShort(d) {
    const date = new Date(d);
    const y = date.getFullYear();
    const mon = date.toLocaleDateString('en-US', { month: 'short' }).toLowerCase();
    const day = String(date.getDate()).padStart(2, '0');
    return `${y} · ${mon} ${day}`;
}

// Render the featured card's right-side decoration card. Specific to each
// recipe slug - designed so visitors see something unique to the recipe, not
// a placeholder. Falls back to a generic metadata card if the slug doesn't
// have a custom decoration.
function renderFeaturedDecoration(r) {
    const tag = (r.tags && r.tags[0]) || r.type || 'recipe';
    if (r.slug === 'gpt-5-6-changed-the-plan') {
        return `<div class="provider-route-card" aria-label="Claude and ChatGPT connected through Atelier" style="border:1px solid var(--line2);background:rgba(233,234,232,.72);padding:26px;font-family:var(--mono);font-size:12px;color:var(--mute);">
            <div style="display:flex;align-items:center;gap:14px;">
                <span style="color:${CLAUDE_CORAL};width:50px;height:50px;display:flex;align-items:center;justify-content:center;border:1px solid currentColor;background:var(--paper2);" title="Claude">${providerMark(CLAUDE_MARK_PATH, 'Claude', 28)}</span>
                <span style="height:1px;flex:1;background:linear-gradient(90deg,rgba(217,119,87,.55),var(--line2),rgba(16,163,127,.55));position:relative;"><i style="position:absolute;width:7px;height:7px;left:50%;top:50%;border:1px solid var(--line2);background:var(--paper);transform:translate(-50%,-50%) rotate(45deg);"></i></span>
                <span style="color:${CHATGPT_GREEN};width:50px;height:50px;display:flex;align-items:center;justify-content:center;border:1px solid currentColor;background:var(--paper2);" title="ChatGPT">${providerMark(CHATGPT_MARK_PATH, 'ChatGPT', 28)}</span>
            </div>
            <div style="display:flex;justify-content:space-between;align-items:end;margin-top:26px;padding-top:18px;border-top:1px solid var(--line);gap:16px;">
                <div><span style="display:block;font-size:10px;letter-spacing:.12em;text-transform:uppercase;margin-bottom:5px;">model</span><strong style="font-family:var(--helv);font-size:22px;font-weight:500;letter-spacing:-.02em;color:var(--ink);">GPT-5.6 Sol</strong></div>
                <span style="color:var(--ink);text-align:right;line-height:1.45;">one workshop<br>two native sessions</span>
            </div>
        </div>`;
    }
    if (r.slug === 'welcome-to-atelier') {
        return `<div style="border:1px solid var(--line2);background:var(--paper);padding:24px;font-family:var(--mono);font-size:12px;line-height:1.75;color:var(--mute);">
            <div style="color:var(--ink);margin-bottom:12px;">recipe.atelier</div>
            work &nbsp;→ atelier (display name)<br>
            mark &nbsp;= dovetail joint<br>
            site &nbsp;= workshop framing<br>
            bench = loops · agents · harnesses
            <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--line);color:var(--ink);">→ open the workshop<br>&nbsp;&nbsp;same binary · same files · sharper name</div>
        </div>`;
    }
    return `<div style="border:1px solid var(--line2);background:var(--paper);padding:24px;font-family:var(--mono);font-size:12px;line-height:1.75;color:var(--mute);">
        <div style="color:var(--ink);margin-bottom:12px;">recipe.${escHtml(r.slug)}</div>
        type &nbsp;= ${escHtml(r.type)}<br>
        date &nbsp;= ${escHtml(formatDateShort(r.date))}<br>
        tags &nbsp;= ${escHtml((r.tags || []).slice(0, 3).join(', ') || '-')}
        <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--line);color:var(--ink);">→ read · apply · ship</div>
    </div>`;
}

function renderListingPage(recipes) {
    const featured = recipes[0];
    const rest = recipes.slice(1);

    // Category chips - derived from real recipe types so we never advertise
    // a filter that returns an empty list.
    const realTypes = Array.from(new Set(recipes.map(r => r.type)));
    const chips = ['all', ...realTypes];
    const chipMarkup = chips.map((c, i) => {
        const active = i === 0;
        const bg = active ? 'var(--ink)' : 'transparent';
        const color = active ? 'var(--paper)' : 'var(--mute)';
        const border = active ? 'var(--ink)' : 'var(--line2)';
        return `<button class="filter-chip" data-filter="${escHtml(c)}" style="border:1px solid ${border};background:${bg};color:${color};padding:6px 12px;font-family:var(--mono);font-size:11.5px;cursor:pointer;letter-spacing:.02em;">${escHtml(c)}</button>`;
    }).join('');

    const featuredCard = featured
        ? `<a href="${escHtml(featured.slug)}.html" class="featured-card${featured.providerStory ? ' provider-featured-card' : ''}" style="text-decoration:none;color:var(--ink);display:grid;grid-template-columns:1.25fr 1fr;gap:48px;align-items:center;border:1px solid var(--line2);background:var(--paper2);padding:44px;">
            <div>
                <div style="display:flex;align-items:center;gap:12px;font-family:var(--mono);font-size:11px;color:var(--mute);margin-bottom:18px;">
                    <span style="border:1px solid var(--line2);padding:3px 9px;letter-spacing:.06em;">${escHtml(featured.type)}</span>
                    <span>featured</span>
                    ${featured.readTime ? `<span>· ${escHtml(featured.readTime)} min</span>` : ''}
                </div>
                <h2 style="font-family:var(--helv);font-weight:500;font-size:38px;line-height:1.05;letter-spacing:-.03em;margin:0 0 16px;">${escHtml(featured.title)}</h2>
                <p style="font-family:var(--helv);font-size:17px;line-height:1.55;color:rgba(27,28,30,.74);margin:0 0 22px;max-width:46ch;">${escHtml(featured.description)}</p>
                <span style="font-family:var(--mono);font-size:12.5px;border-bottom:1px solid var(--ink);padding-bottom:2px;">read the recipe →</span>
            </div>
            ${renderFeaturedDecoration(featured)}
        </a>`
        : '';

    const rows = rest.map((r, i) => {
        const last = i === rest.length - 1;
        const border = last ? '' : 'border-bottom:1px solid var(--line);';
        return `<a class="recipe-row" data-type="${escHtml(r.type)}" href="${escHtml(r.slug)}.html" style="text-decoration:none;color:var(--ink);display:grid;grid-template-columns:170px 1fr 96px;gap:32px;padding:30px 0;${border}align-items:start;">
            <div style="font-family:var(--mono);font-size:11.5px;color:var(--mute);line-height:1.7;">
                <div>${escHtml(formatDateShort(r.date))}</div>
                <div style="margin-top:6px;"><span style="border:1px solid var(--line2);padding:2px 7px;">${escHtml(r.type)}</span></div>
            </div>
            <div>
                <h3 style="font-family:var(--helv);font-weight:500;font-size:23px;letter-spacing:-.015em;margin:0 0 7px;">${escHtml(r.title)}</h3>
                <p style="font-family:var(--helv);font-size:16px;line-height:1.5;color:rgba(27,28,30,.72);margin:0;max-width:62ch;">${escHtml(r.description)}</p>
            </div>
            <div style="font-family:var(--mono);font-size:11.5px;color:var(--mute);text-align:right;">${r.readTime ? `${escHtml(r.readTime)} min` : ''}</div>
        </a>`;
    }).join('');

    const emptyMarkup = recipes.length === 0
        ? `<p style="font-family:var(--mono);font-size:13px;color:var(--mute);padding:80px 0;text-align:center;">No recipes yet - first one coming soon.</p>`
        : '';

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Recipes - Atelier</title>
    <meta name="description" content="Field notes from the workshop, with practical playbooks for Claude and Codex. Models, agents, harnesses, and the small moves that turn prompts into finished work.">
    <link rel="canonical" href="${SITE_URL}/recipes/">
    <link rel="alternate" type="application/rss+xml" title="Atelier Recipes" href="${SITE_URL}/recipes/feed.xml">

    <meta property="og:type" content="website">
    <meta property="og:title" content="Recipes - Atelier">
    <meta property="og:description" content="Field notes from the workshop, with practical playbooks for Claude and Codex.">
    <meta property="og:url" content="${SITE_URL}/recipes/">
    <meta property="og:image" content="${SITE_URL}/og-image.png">
    <meta property="og:site_name" content="Atelier">

    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="Recipes - Atelier">
    <meta name="twitter:description" content="Field notes from the workshop, with practical playbooks for Claude and Codex.">
    <meta name="twitter:image" content="${SITE_URL}/og-image.png">

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
        .featured-card { transition: background .12s ease; }
        .featured-card:hover { background: #fff !important; }
        .provider-featured-card {
            position: relative;
            overflow: hidden;
            background:
                radial-gradient(circle at 0 0, rgba(217,119,87,.09), transparent 35%),
                radial-gradient(circle at 100% 100%, rgba(16,163,127,.08), transparent 38%),
                var(--paper2) !important;
        }
        .provider-featured-card::before {
            content: '';
            position: absolute;
            inset: 0 auto 0 0;
            width: 3px;
            background: linear-gradient(180deg, ${CLAUDE_CORAL}, ${CHATGPT_GREEN});
        }
        .recipe-row { transition: background .12s ease; }
        .recipe-row:hover { background: var(--paper2) !important; }
        .filter-chip { transition: background .12s ease, color .12s ease, border-color .12s ease; }
        .footer-link { transition: color .12s ease; }
        .footer-link:hover { color: var(--ink) !important; }

        /* Mobile nav - full-screen paper overlay with editorial-sized links */
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
            .featured-card { grid-template-columns: 1fr !important; gap: 24px !important; padding: 26px !important; }
            .featured-card h2 { font-size: 28px !important; }
            .recipe-row { grid-template-columns: 1fr !important; gap: 10px !important; padding: 24px 0 !important; }
            .recipe-row > div:last-child { text-align: left !important; }
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
                <a class="nav-link" href="/releases.html" style="color:var(--mute);text-decoration:none;">changelog</a>
                <a href="/recipes/" style="color:var(--ink);text-decoration:none;">recipes</a>
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
            <a class="menu-link" href="/releases.html" style="text-decoration:none;color:var(--ink);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">changelog</a>
            <a class="menu-link" href="/recipes/" style="text-decoration:none;color:var(--mute);font-family:var(--helv);font-weight:500;font-size:clamp(38px,11vw,56px);letter-spacing:-.03em;line-height:1;">recipes</a>
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

        <!-- masthead -->
        <div style="border-bottom:1px solid var(--line2);padding-bottom:34px;">
            <div style="font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mute);margin-bottom:16px;">field notes from the workshop</div>
            <h1 style="font-family:var(--helv);font-weight:500;font-size:54px;line-height:1.02;letter-spacing:-.035em;margin:0;">Recipes</h1>
            <p style="font-family:var(--helv);font-size:18px;line-height:1.5;color:rgba(27,28,30,.78);margin:18px 0 0;max-width:54ch;">Practical playbooks for working across models, agents, harnesses, and the small moves that turn prompts into finished work.</p>
        </div>

        <!-- category row -->
        <div style="display:flex;gap:9px;flex-wrap:wrap;font-family:var(--mono);font-size:11.5px;padding:26px 0 40px;">
            ${chipMarkup}
        </div>

        ${featuredCard}

        <!-- index list -->
        <div style="margin-top:8px;">
            ${rows}
            ${emptyMarkup}
        </div>

    </main>

    <footer style="border-top:1px solid var(--line);">
        <div class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:36px 40px;font-family:var(--mono);font-size:11px;color:var(--mute);display:flex;justify-content:space-between;flex-wrap:wrap;gap:16px;">
            <span>© mmxxvi atelier · a workshop for serious model work</span>
            <span><a class="footer-link" href="/" style="color:var(--mute);text-decoration:none;">← home</a></span>
        </div>
    </footer>
</div>

<script>
    (function () {
        var chips = document.querySelectorAll('.filter-chip');
        var rows = document.querySelectorAll('.recipe-row');
        chips.forEach(function (chip) {
            chip.addEventListener('click', function () {
                var filter = chip.getAttribute('data-filter');
                chips.forEach(function (c) {
                    var active = c.getAttribute('data-filter') === filter;
                    c.style.background = active ? 'var(--ink)' : 'transparent';
                    c.style.color = active ? 'var(--paper)' : 'var(--mute)';
                    c.style.borderColor = active ? 'var(--ink)' : 'var(--line2)';
                });
                rows.forEach(function (row) {
                    var match = filter === 'all' || row.getAttribute('data-type') === filter;
                    row.style.display = match ? '' : 'none';
                });
            });
        });
    })();
    (function () {
        var body = document.body;
        var toggle = document.querySelector('[data-menu-toggle]');
        var closeBtn = document.querySelector('[data-menu-close]');
        var links = document.querySelectorAll('[data-menu-overlay] a');
        function openMenu() { body.setAttribute('data-menu', 'open'); if (toggle) toggle.setAttribute('aria-expanded', 'true'); }
        function closeMenu() { body.removeAttribute('data-menu'); if (toggle) toggle.setAttribute('aria-expanded', 'false'); }
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

// ─── Sitemap ────────────────────────────────────────────────────────────────

function updateSitemap(recipes) {
    const urls = [
        { loc: `${SITE_URL}/`, priority: 1.0, changefreq: 'weekly' },
        { loc: `${SITE_URL}/recipes/`, priority: 0.9, changefreq: 'weekly' },
        ...recipes.map(r => ({
            loc: `${SITE_URL}/recipes/${r.slug}.html`,
            priority: 0.7,
            changefreq: 'monthly',
            lastmod: new Date(r.date).toISOString().split('T')[0]
        }))
    ];
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map(u => `    <url>
        <loc>${u.loc}</loc>
${u.lastmod ? `        <lastmod>${u.lastmod}</lastmod>\n` : ''}        <changefreq>${u.changefreq}</changefreq>
        <priority>${u.priority.toFixed(1)}</priority>
    </url>`).join('\n')}
</urlset>
`;
    fs.writeFileSync(SITEMAP, xml, 'utf8');
}

function writeFeed(recipes) {
    const feedPath = path.join(OUT, 'feed.xml');
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
    <channel>
        <title>Atelier Recipes</title>
        <link>${SITE_URL}/recipes/</link>
        <description>Field notes from the Atelier workshop for Claude and Codex.</description>
        <language>en-us</language>
        <atom:link href="${SITE_URL}/recipes/feed.xml" rel="self" type="application/rss+xml" />
${recipes.map(r => `        <item>
            <title>${escXml(r.title)}</title>
            <link>${SITE_URL}/recipes/${encodeURIComponent(r.slug)}.html</link>
            <guid isPermaLink="true">${SITE_URL}/recipes/${encodeURIComponent(r.slug)}.html</guid>
            <pubDate>${new Date(r.date).toUTCString()}</pubDate>
            <description>${escXml(r.description)}</description>
        </item>`).join('\n')}
    </channel>
</rss>
`;
    fs.writeFileSync(feedPath, xml, 'utf8');
}

function escXml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&apos;');
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
    if (!fs.existsSync(SRC)) {
        console.error(`No recipes/ folder at ${SRC} - nothing to build.`);
        process.exit(1);
    }
    if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });

    // Configure marked: GFM, strip HTML
    marked.setOptions({ gfm: true, breaks: false });

    const files = fs.readdirSync(SRC).filter(f => f.endsWith('.md'));
    if (files.length === 0) {
        console.warn('No .md files in recipes/ - still generating empty listing page.');
    }

    const recipes = [];

    for (const filename of files) {
        const filepath = path.join(SRC, filename);
        const raw = fs.readFileSync(filepath, 'utf8');
        const parsed = matter(raw);
        const data = parsed.data;

        validate(data, filename);

        data.slug = data.slug || path.basename(filename, '.md');
        data.bodyHtml = marked.parse(parsed.content.trim());

        recipes.push(data);
    }

    // Sort by date, newest first
    recipes.sort((a, b) => new Date(b.date) - new Date(a.date));

    // Wire up "related" based on shared tags (simple: same type, or shared tag)
    for (const r of recipes) {
        const myTags = new Set(r.tags || []);
        r.related = recipes
            .filter(o => o.slug !== r.slug)
            .map(o => {
                const sharedTags = (o.tags || []).filter(t => myTags.has(t)).length;
                const sameType = o.type === r.type ? 1 : 0;
                return { recipe: o, score: sharedTags * 2 + sameType };
            })
            .filter(x => x.score > 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, 3)
            .map(x => x.recipe);
    }

    // Wire each recipe's "next" pointer to the recipe immediately older in the
    // list (recipes are sorted newest-first). The oldest recipe has no next.
    for (let i = 0; i < recipes.length; i++) {
        recipes[i].next = recipes[i + 1] || null;
    }

    // Write detail pages
    for (const r of recipes) {
        const outFile = path.join(OUT, `${r.slug}.html`);
        fs.writeFileSync(outFile, renderDetailPage(r), 'utf8');
        console.log(`✓ ${r.slug}.html`);
    }

    // Generate per-recipe OG images (1200x630 PNG via satori)
    const ogDir = path.join(OUT, 'og');
    if (!fs.existsSync(ogDir)) fs.mkdirSync(ogDir, { recursive: true });
    for (const r of recipes) {
        const ogPath = path.join(ogDir, `${r.slug}.png`);
        try {
            await generateOgImage(r, ogPath);
            console.log(`✓ og/${r.slug}.png`);
        } catch (e) {
            console.warn(`⚠️  OG image for ${r.slug} failed: ${e.message}`);
        }
    }

    // Write listing page
    const listFile = path.join(OUT, 'index.html');
    fs.writeFileSync(listFile, renderListingPage(recipes), 'utf8');
    console.log(`✓ index.html (${recipes.length} recipes)`);

    // Update sitemap
    updateSitemap(recipes);
    console.log(`✓ sitemap.xml`);

    writeFeed(recipes);
    console.log(`✓ feed.xml`);

    console.log(`\nBuilt ${recipes.length} recipe${recipes.length === 1 ? '' : 's'} into ${path.relative(ROOT, OUT)}/`);
}

main().catch(err => {
    console.error('Build failed:', err);
    process.exit(1);
});
