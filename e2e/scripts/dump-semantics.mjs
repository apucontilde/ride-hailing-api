/**
 * Probes the semantics tree of a built Flutter web app.
 *
 * Diagnostic tool, not a test. Flutter web renders to a canvas, so the only
 * way a DOM driver can see the UI is through the semantics tree that
 * `flt-semantics-placeholder` builds. When a spec fails on a locator, run this
 * to see the labels that actually exist rather than guessing.
 *
 * Usage:
 *   node scripts/dump-semantics.mjs http://127.0.0.1:8091 "New Ride Offer"
 */

import { chromium } from '@playwright/test';

const url = process.argv[2] ?? 'http://127.0.0.1:8091';
const filter = process.argv[3] ?? '';

const browser = await chromium.launch({ channel: 'msedge', headless: true });
const ctx = await browser.newContext({
  permissions: ['geolocation'],
  geolocation: { latitude: 40.713, longitude: -74.006 },
  locale: 'en-US',
});
const page = await ctx.newPage();

page.on('console', (m) => {
  if (m.type() === 'error') console.log(`[console.error] ${m.text()}`);
});
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

await page.goto(`${url}/?e2e=1`);

console.log('waiting for flutter-view...');
await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60_000 });
console.log('flutter-view attached');

const placeholder = await page.locator('flt-semantics-placeholder').count();
console.log(`flt-semantics-placeholder count: ${placeholder}`);

try {
  await page.waitForSelector('flt-semantics[aria-label]', { timeout: 30_000 });
  console.log('semantics tree is live\n');
} catch {
  console.log('NO semantics nodes after 30s — the ?e2e=1 hook did not fire\n');
}

const nodes = await page.evaluate(() => {
  const out = [];
  for (const el of document.querySelectorAll('flt-semantics')) {
    const label = el.getAttribute('aria-label');
    const role = el.getAttribute('role');
    const tag = el.tagName.toLowerCase();
    const r = el.getBoundingClientRect();
    if (label || role) {
      out.push({
        label,
        role,
        tag,
        w: Math.round(r.width),
        h: Math.round(r.height),
        x: Math.round(r.x),
        y: Math.round(r.y),
      });
    }
  }
  return out;
});

console.log(`${nodes.length} semantics nodes\n`);
const shown = filter ? nodes.filter((n) => (n.label ?? '').includes(filter)) : nodes;
for (const n of shown) {
  const size = n.w && n.h ? `${n.w}x${n.h}@${n.x},${n.y}` : 'zero-size';
  console.log(`  [${n.role ?? '-'}] ${JSON.stringify(n.label ?? '')}  (${n.tag}, ${size})`);
}

await page.screenshot({ path: 'test-results/semantics-probe.png', fullPage: false });
console.log('\nscreenshot -> test-results/semantics-probe.png');

await browser.close();
