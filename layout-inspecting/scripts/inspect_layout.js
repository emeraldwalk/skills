#!/usr/bin/env node
/**
 * inspect_layout.js - Playwright-based layout inspector
 *
 * Navigates to a URL, walks the visible DOM, and returns a JSON tree of
 * layout-relevant nodes — those whose background or border color differs
 * from their parent's background.  The result lets an AI agent "see" the
 * visual box structure of the page without processing screenshots.
 *
 * Usage:
 *   node inspect_layout.js <url> [options]
 *
 * Options:
 *   --width <px>        Viewport width  (default: 1280)
 *   --height <px>       Viewport height (default: 800)
 *   --full-page         Capture the full scrollable page (default: viewport only)
 *   --max-depth <n>     Max DOM depth to recurse (default: 12)
 *   --min-size <px>     Skip nodes smaller than this in both dimensions (default: 4)
 *   --timeout <ms>      Navigation timeout in ms (default: 30000)
 *   --output <file>     Write JSON to file instead of stdout
 *   --wait-for <sel>    Wait for a CSS selector to appear before inspecting
 *   --help              Show this help
 *
 * Dependencies are installed automatically on first run into the script's own
 * directory (~/.claude/skills/layout-inspecting/scripts/node_modules).
 *
 * Exit codes:
 *   0  success
 *   1  bad arguments
 *   2  navigation/timeout error
 *   3  inspection error
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// ─── self-installing dependency bootstrap ───────────────────────────────────
// playwright is installed into node_modules/ beside this script so the skill
// works from any working directory without polluting the user's project.

const SCRIPT_DIR = __dirname;
const NM = path.join(SCRIPT_DIR, 'node_modules');
const PLAYWRIGHT_ENTRY = path.join(NM, 'playwright');

function ensureDependencies() {
  if (!fs.existsSync(PLAYWRIGHT_ENTRY)) {
    console.error('Installing playwright into skill scripts directory (first run only)...');
    const npm = spawnSync('npm', ['install', '--prefix', SCRIPT_DIR, 'playwright'], {
      stdio: 'inherit',
      encoding: 'utf8',
    });
    if (npm.status !== 0) {
      console.error('npm install failed. Make sure npm/node are available.');
      process.exit(2);
    }
  }

  // Check whether the Chromium browser binary is present by asking playwright
  // directly via its public API.
  const chromiumBrowserPath = (() => {
    try {
      return require(PLAYWRIGHT_ENTRY).chromium.executablePath();
    } catch {
      return null;
    }
  })();

  if (!chromiumBrowserPath || !fs.existsSync(chromiumBrowserPath)) {
    console.error('Installing Chromium browser (first run only)...');
    const install = spawnSync(
      process.execPath, // use same node binary
      [path.join(NM, '.bin', 'playwright'), 'install', 'chromium'],
      { stdio: 'inherit', encoding: 'utf8' }
    );
    if (install.status !== 0) {
      console.error('playwright install chromium failed.');
      process.exit(2);
    }
  }
}

ensureDependencies();

// Now safe to require playwright from the skill-local node_modules
const { chromium } = require(PLAYWRIGHT_ENTRY);

// ─── argument parsing ───────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    url: null,
    width: 1280,
    height: 800,
    fullPage: false,
    maxDepth: 12,
    minSize: 4,
    timeout: 30000,
    output: null,
    waitFor: null,
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--help') {
      printHelp();
      process.exit(0);
    } else if (a === '--full-page') {
      opts.fullPage = true;
    } else if (a === '--width') {
      opts.width = parseInt(args[++i], 10);
    } else if (a === '--height') {
      opts.height = parseInt(args[++i], 10);
    } else if (a === '--max-depth') {
      opts.maxDepth = parseInt(args[++i], 10);
    } else if (a === '--min-size') {
      opts.minSize = parseInt(args[++i], 10);
    } else if (a === '--timeout') {
      opts.timeout = parseInt(args[++i], 10);
    } else if (a === '--output') {
      opts.output = args[++i];
    } else if (a === '--wait-for') {
      opts.waitFor = args[++i];
    } else if (!a.startsWith('--')) {
      opts.url = a;
    } else {
      console.error(`Unknown option: ${a}`);
      process.exit(1);
    }
  }

  if (!opts.url) {
    console.error('Error: URL is required.');
    printHelp();
    process.exit(1);
  }

  return opts;
}

function printHelp() {
  console.log(`Usage: node inspect_layout.js <url> [options]

Options:
  --width <px>        Viewport width  (default: 1280)
  --height <px>       Viewport height (default: 800)
  --full-page         Capture the full scrollable page (default: viewport only)
  --max-depth <n>     Max DOM depth to recurse (default: 12)
  --min-size <px>     Skip nodes smaller than this in both dimensions (default: 4)
  --timeout <ms>      Navigation timeout in ms (default: 30000)
  --output <file>     Write JSON to file instead of stdout
  --wait-for <sel>    Wait for a CSS selector to appear before inspecting
  --help              Show this help`);
}

// ─── browser-side inspection logic (serialised and eval'd in page) ──────────

/**
 * This function runs inside the browser page via page.evaluate().
 * It receives configuration from the outer Node.js scope.
 */
function buildLayoutTree(config) {
  const { maxDepth, minSize, viewportWidth, viewportHeight, fullPage } = config;

  // ── colour helpers ──────────────────────────────────────────────────────

  /**
   * Parse "rgba(r, g, b, a)" or "rgb(r, g, b)" or "transparent" into
   * { r, g, b, a }.  Returns null for unparseable values.
   */
  function parseColor(str) {
    if (!str || str === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
    const m = str.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
    if (!m) return null;
    return {
      r: parseInt(m[1], 10),
      g: parseInt(m[2], 10),
      b: parseInt(m[3], 10),
      a: m[4] !== undefined ? parseFloat(m[4]) : 1,
    };
  }

  function colorsEqual(a, b) {
    if (!a || !b) return false;
    // Treat fully-transparent as equal regardless of rgb
    if (a.a === 0 && b.a === 0) return true;
    return a.r === b.r && a.g === b.g && a.b === b.b && Math.abs(a.a - b.a) < 0.01;
  }

  function isTransparent(c) {
    return !c || c.a === 0;
  }

  /**
   * Format a color back to a compact CSS string.
   */
  function colorToString(c) {
    if (!c || c.a === 0) return 'transparent';
    if (c.a === 1) return `rgb(${c.r},${c.g},${c.b})`;
    return `rgba(${c.r},${c.g},${c.b},${c.a})`;
  }

  // ── effective background resolution ────────────────────────────────────

  /**
   * Walk up the ancestor chain to find the first non-transparent background,
   * starting from `el` itself.  Defaults to white (page canvas default).
   */
  function effectiveBg(el) {
    let node = el;
    while (node && node !== document.documentElement.parentElement) {
      const bg = parseColor(getComputedStyle(node).backgroundColor);
      if (bg && bg.a > 0) return bg;
      node = node.parentElement;
    }
    return { r: 255, g: 255, b: 255, a: 1 }; // browser default canvas
  }

  // ── border visibility check ─────────────────────────────────────────────

  /**
   * Return the first visible border color on the element that differs from
   * the given parent background, or null if no such border exists.
   */
  function visibleBorderColor(el, parentBg) {
    const style = getComputedStyle(el);
    const sides = ['Top', 'Right', 'Bottom', 'Left'];
    for (const side of sides) {
      const width = parseFloat(style[`border${side}Width`]);
      const style2 = style[`border${side}Style`];
      if (width > 0 && style2 !== 'none' && style2 !== 'hidden') {
        const color = parseColor(style[`border${side}Color`]);
        if (color && !isTransparent(color) && !colorsEqual(color, parentBg)) {
          return color;
        }
      }
    }
    return null;
  }

  // ── tag classification helpers ──────────────────────────────────────────

  const SKIP_TAGS = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'HEAD', 'META', 'LINK', 'TITLE',
    'TEMPLATE', 'SVG', 'PATH', 'DEFS', 'USE',
  ]);

  const INLINE_TAGS = new Set([
    'SPAN', 'A', 'STRONG', 'EM', 'B', 'I', 'U', 'SMALL', 'LABEL',
    'ABBR', 'ACRONYM', 'CITE', 'CODE', 'KBD', 'SAMP', 'VAR', 'Q',
    'SUB', 'SUP', 'TIME', 'MARK', 'BDI', 'BDO', 'WBR',
  ]);

  /**
   * Get a short, readable label for a node: prefer id, then aria-label,
   * then first 60 chars of innerText.
   */
  function nodeLabel(el) {
    const id = el.id ? `#${el.id}` : '';
    const cls = el.classList.length
      ? `.${Array.from(el.classList).slice(0, 3).join('.')}`
      : '';
    return `${el.tagName.toLowerCase()}${id}${cls}`;
  }

  function textSnippet(el) {
    const text = (el.innerText || '').replace(/\s+/g, ' ').trim();
    return text.length > 80 ? text.slice(0, 77) + '...' : text;
  }

  // ── bounding rect helpers ───────────────────────────────────────────────

  function rectVisible(rect) {
    if (rect.width < minSize || rect.height < minSize) return false;
    if (!fullPage) {
      // Must overlap with the viewport
      if (rect.bottom < 0 || rect.top > viewportHeight) return false;
      if (rect.right < 0 || rect.left > viewportWidth) return false;
    }
    return true;
  }

  function roundRect(rect) {
    return {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    };
  }

  // ── main recursive walk ─────────────────────────────────────────────────

  /**
   * Walk the DOM from `el`, collecting nodes that visually "stand out" from
   * their parent's background via a different background or a visible border.
   *
   * Returns an array of node descriptor objects (children property added when
   * there are interesting descendants).
   */
  function walk(el, parentBg, depth) {
    if (depth > maxDepth) return [];
    if (SKIP_TAGS.has(el.tagName)) return [];

    const rect = el.getBoundingClientRect();
    if (!rectVisible(rect)) return [];

    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
      return [];
    }

    const ownBg = parseColor(style.backgroundColor);
    const bgDiffers = ownBg && ownBg.a > 0 && !colorsEqual(ownBg, parentBg);
    const borderColor = visibleBorderColor(el, parentBg);
    const isInteresting = bgDiffers || borderColor !== null;

    // Determine the effective bg for children: if this element has an opaque
    // background, children inherit that; otherwise they see the parent's bg.
    const childBg = (ownBg && ownBg.a > 0) ? ownBg : parentBg;

    // Recurse into children
    const children = [];
    for (const child of el.children) {
      const subtree = walk(child, childBg, depth + 1);
      children.push(...subtree);
    }

    if (!isInteresting) {
      // Pass-through: bubble interesting descendants up
      return children;
    }

    // Build descriptor for this interesting node
    const descriptor = {
      label: nodeLabel(el),
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || undefined,
      rect: roundRect(rect),
      background: bgDiffers ? colorToString(ownBg) : colorToString(parentBg),
    };

    if (borderColor) {
      descriptor.border = colorToString(borderColor);
    }

    const snippet = textSnippet(el);
    if (snippet) descriptor.text = snippet;

    if (children.length > 0) {
      descriptor.children = children;
    }

    return [descriptor];
  }

  // ── document root ───────────────────────────────────────────────────────

  const htmlEl = document.documentElement;
  const htmlStyle = getComputedStyle(htmlEl);
  const bodyStyle = getComputedStyle(document.body);

  // Resolve the canvas/root background (html or body, whichever is opaque)
  let rootBg =
    parseColor(htmlStyle.backgroundColor) ||
    parseColor(bodyStyle.backgroundColor) ||
    { r: 255, g: 255, b: 255, a: 1 };

  if (rootBg.a === 0) rootBg = { r: 255, g: 255, b: 255, a: 1 };

  const docRect = {
    x: 0,
    y: 0,
    width: fullPage ? Math.max(document.documentElement.scrollWidth, viewportWidth) : viewportWidth,
    height: fullPage ? Math.max(document.documentElement.scrollHeight, viewportHeight) : viewportHeight,
  };

  const children = [];
  for (const child of document.body.children) {
    const subtree = walk(child, rootBg, 1);
    children.push(...subtree);
  }

  return {
    label: 'document',
    tag: 'document',
    rect: docRect,
    background: colorToString(rootBg),
    children: children.length > 0 ? children : undefined,
  };
}

// ─── main ───────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch (err) {
    console.error(`Failed to launch browser: ${err.message}`);
    console.error('Make sure Playwright and Chromium are installed:');
    console.error('  npm install playwright');
    console.error('  npx playwright install chromium');
    process.exit(2);
  }

  try {
    const context = await browser.newContext({
      viewport: { width: opts.width, height: opts.height },
    });
    const page = await context.newPage();

    // Navigate
    try {
      await page.goto(opts.url, {
        waitUntil: 'networkidle',
        timeout: opts.timeout,
      });
    } catch (err) {
      console.error(`Navigation failed: ${err.message}`);
      process.exit(2);
    }

    // Optional selector wait
    if (opts.waitFor) {
      try {
        await page.waitForSelector(opts.waitFor, { timeout: opts.timeout });
      } catch (err) {
        console.error(`Timed out waiting for selector "${opts.waitFor}": ${err.message}`);
        process.exit(2);
      }
    }

    // Run inspection inside the page
    let tree;
    try {
      tree = await page.evaluate(buildLayoutTree, {
        maxDepth: opts.maxDepth,
        minSize: opts.minSize,
        viewportWidth: opts.width,
        viewportHeight: opts.height,
        fullPage: opts.fullPage,
      });
    } catch (err) {
      console.error(`Layout inspection failed: ${err.message}`);
      process.exit(3);
    }

    const result = {
      url: page.url(),
      viewport: { width: opts.width, height: opts.height },
      fullPage: opts.fullPage,
      capturedAt: new Date().toISOString(),
      layout: tree,
    };

    const json = JSON.stringify(result, null, 2);

    if (opts.output) {
      fs.writeFileSync(opts.output, json, 'utf8');
      console.error(`Layout written to ${opts.output}`);
    } else {
      process.stdout.write(json + '\n');
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(`Unexpected error: ${err.message}`);
  process.exit(3);
});
