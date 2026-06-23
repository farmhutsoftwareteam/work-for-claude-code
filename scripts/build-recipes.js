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
const SITE_URL = 'https://work.munyamakosa.com';

// ─── Helpers ────────────────────────────────────────────────────────────────

function escHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
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
        announcement: '#1b1c1e' // graphite — brand-aligned for launch posts
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
    // install block is optional — recipes can be pure tutorials (e.g. workflows)
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
    const badgeStyle = `background: ${typeColor(data.type)}22; color: ${typeColor(data.type)};`;
    const relatedHtml = data.related && data.related.length
        ? `<div class="related">
            <h3>Related recipes</h3>
            <div class="related-list">
                ${data.related.map(r => `<a href="${escHtml(r.slug)}.html"><span class="related-type">${escHtml(typeLabel(r.type))}</span>${escHtml(r.title)}</a>`).join('')}
            </div>
        </div>`
        : '';

    const pageUrl = `${SITE_URL}/recipes/${data.slug}.html`;

    // SEO overrides: invisible to readers, used only in <head> / structured data.
    const seoTitle = data.seoTitle || data.title;
    const metaDesc = data.metaDescription || data.description;
    // Default to per-recipe generated OG card unless the recipe explicitly overrides via `image:`.
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

    <!-- Open Graph -->
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

    <!-- Twitter -->
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:site" content="@munyamakosa">
    <meta name="twitter:creator" content="@munyamakosa">
    <meta name="twitter:title" content="${escHtml(seoTitle)}">
    <meta name="twitter:description" content="${escHtml(metaDesc)}">
    <meta name="twitter:image" content="${ogImage}">
    <meta name="twitter:image:alt" content="${escHtml(ogImageAlt)}">

    <!-- Article JSON-LD -->
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

    <!-- Breadcrumb JSON-LD -->
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

    <link rel="icon" type="image/png" href="../icon-256.png">
    <style>${SHARED_STYLE}${DETAIL_STYLE}</style>
</head>
<body>
${renderNav('recipes')}
<main>
    <header class="article-header">
        <div class="container-narrow">
            <a href="./" class="back-link">← All recipes</a>
            <div class="article-meta">
                <span class="type-badge" style="${badgeStyle}">${escHtml(typeLabel(data.type))}</span>
                <span class="meta-item">${escHtml(formatDate(data.date))}</span>
                ${data.readTime ? `<span class="meta-dot">·</span><span class="meta-item">${escHtml(data.readTime)} min read</span>` : ''}
            </div>
            <h1 class="article-title">${escHtml(data.title)}</h1>
            <p class="article-description">${escHtml(data.description)}</p>
        </div>
    </header>

    <article class="article-body">
        <div class="container-narrow">
            ${data.bodyHtml}

            ${data.install ? `
            <div class="install-card">
                <div class="install-header">
                    <div>
                        <span class="install-label-eyebrow">Install</span>
                        <span class="install-label">${escHtml(data.install.label)}</span>
                    </div>
                    <button class="copy-btn" data-copy aria-label="Copy to clipboard">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 01-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 011.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 00-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 01-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5a3.375 3.375 0 00-3.375-3.375H9.75" /></svg>
                        <span class="copy-label">Copy</span>
                    </button>
                </div>
                <div class="install-body">
                    <pre><code>${escHtml(data.install.content)}</code></pre>
                </div>
            </div>
            ` : ''}

            ${relatedHtml}
        </div>
    </article>
</main>
${renderFooter()}
<script>
(function() {
    document.querySelectorAll('[data-copy]').forEach(function(btn) {
        btn.addEventListener('click', function() {
            var code = btn.closest('.install-card').querySelector('code').innerText;
            (async function() {
                try {
                    await navigator.clipboard.writeText(code);
                    var label = btn.querySelector('.copy-label');
                    var original = label.textContent;
                    label.textContent = 'Copied ✓';
                    setTimeout(function() { label.textContent = original; }, 1600);
                } catch (e) {}
            })();
        });
    });
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
// recipe slug — designed so visitors see something unique to the recipe, not
// a placeholder. Falls back to a generic metadata card if the slug doesn't
// have a custom decoration.
function renderFeaturedDecoration(r) {
    const tag = (r.tags && r.tags[0]) || r.type || 'recipe';
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
        tags &nbsp;= ${escHtml((r.tags || []).slice(0, 3).join(', ') || '—')}
        <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--line);color:var(--ink);">→ read · apply · ship</div>
    </div>`;
}

function renderListingPage(recipes) {
    const featured = recipes[0];
    const rest = recipes.slice(1);

    // Category chips — derived from real recipe types so we never advertise
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
        ? `<a href="${escHtml(featured.slug)}.html" class="featured-card" style="text-decoration:none;color:var(--ink);display:grid;grid-template-columns:1.25fr 1fr;gap:48px;align-items:center;border:1px solid var(--line2);background:var(--paper2);padding:44px;">
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
        ? `<p style="font-family:var(--mono);font-size:13px;color:var(--mute);padding:80px 0;text-align:center;">No recipes yet — first one coming soon.</p>`
        : '';

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Recipes — Atelier</title>
    <meta name="description" content="Field notes from the workshop — practical playbooks for Claude Code. Loops, agents, harnesses and the small moves that separate dabblers from power users.">
    <link rel="canonical" href="${SITE_URL}/recipes/">

    <meta property="og:type" content="website">
    <meta property="og:title" content="Recipes — Atelier">
    <meta property="og:description" content="Field notes from the workshop — practical playbooks for Claude Code.">
    <meta property="og:url" content="${SITE_URL}/recipes/">
    <meta property="og:image" content="${SITE_URL}/og-image.png">
    <meta property="og:site_name" content="Atelier">

    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="Recipes — Atelier">
    <meta name="twitter:description" content="Field notes from the workshop — practical playbooks for Claude Code.">
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
        .recipe-row { transition: background .12s ease; }
        .recipe-row:hover { background: var(--paper2) !important; }
        .filter-chip { transition: background .12s ease, color .12s ease, border-color .12s ease; }
        .footer-link { transition: color .12s ease; }
        .footer-link:hover { color: var(--ink) !important; }

        @media (max-width: 800px) {
            .responsive-padding { padding-left: 24px !important; padding-right: 24px !important; }
            .responsive-nav { gap: 18px !important; }
            .featured-card { grid-template-columns: 1fr !important; gap: 28px !important; padding: 28px !important; }
            .featured-card h2 { font-size: 28px !important; }
            .recipe-row { grid-template-columns: 1fr !important; gap: 10px !important; }
            .recipe-row > div:last-child { text-align: left !important; }
            h1 { font-size: 40px !important; }
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
            <nav class="responsive-nav" style="display:flex;align-items:center;gap:30px;font-family:var(--mono);font-size:12.5px;letter-spacing:.02em;">
                <a class="nav-link" href="/releases.html" style="color:var(--mute);text-decoration:none;">changelog</a>
                <a href="/recipes/" style="color:var(--ink);text-decoration:none;">recipes</a>
                <a class="nav-link" href="/faq.html" style="color:var(--mute);text-decoration:none;">faq</a>
                <a class="nav-link" href="/pricing.html" style="color:var(--mute);text-decoration:none;">pricing</a>
                <a class="nav-cta" href="/#download" style="color:var(--paper);background:var(--ink);text-decoration:none;padding:8px 15px;letter-spacing:.04em;">download</a>
            </nav>
        </div>
    </header>

    <main class="responsive-padding" style="max-width:1180px;margin:0 auto;padding:72px 40px 96px;">

        <!-- masthead -->
        <div style="border-bottom:1px solid var(--line2);padding-bottom:34px;">
            <div style="font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mute);margin-bottom:16px;">field notes from the workshop</div>
            <h1 style="font-family:var(--helv);font-weight:500;font-size:54px;line-height:1.02;letter-spacing:-.035em;margin:0;">Recipes</h1>
            <p style="font-family:var(--helv);font-size:18px;line-height:1.5;color:rgba(27,28,30,.78);margin:18px 0 0;max-width:54ch;">Practical playbooks for Claude&nbsp;Code — loops, agents, harnesses and the small moves that separate dabblers from power users.</p>
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
            <span>© mmxxvi atelier · a workshop for claude code</span>
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

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
    if (!fs.existsSync(SRC)) {
        console.error(`No recipes/ folder at ${SRC} — nothing to build.`);
        process.exit(1);
    }
    if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });

    // Configure marked: GFM, strip HTML
    marked.setOptions({ gfm: true, breaks: false });

    const files = fs.readdirSync(SRC).filter(f => f.endsWith('.md'));
    if (files.length === 0) {
        console.warn('No .md files in recipes/ — still generating empty listing page.');
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

    console.log(`\nBuilt ${recipes.length} recipe${recipes.length === 1 ? '' : 's'} into ${path.relative(ROOT, OUT)}/`);
}

main().catch(err => {
    console.error('Build failed:', err);
    process.exit(1);
});
