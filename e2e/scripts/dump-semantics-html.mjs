/**
 * Dumps the raw HTML of the semantics tree.
 *
 * Diagnostic companion to dump-semantics.mjs. Flutter 3.44's semantics output
 * does not always use `aria-label` for text — it may use inner text, `aria-label`
 * on a child, or a `<span>` inside the node. This prints the actual markup so
 * locators can be written against reality instead of assumption.
 *
 * Usage: node scripts/dump-semantics-html.mjs [url] [maxNodes]
 */

import { chromium } from '@playwright/test';

const url = process.argv[2] ?? 'http://127.0.0.1:8091';
const max = Number(process.argv[3] ?? 40);

const browser = await chromium.launch({ channel: 'msedge', headless: true });
const ctx = await browser.newContext({
  permissions: ['geolocation'],
  geolocation: { latitude: 40.713, longitude: -74.006 },
  locale: 'en-US',
});
const page = await ctx.newPage();
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

await page.goto(`${url}/?e2e=1`);
await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60_000 });
await page.waitForTimeout(6000);

const dump = await page.evaluate((limit) => {
  const host = document.querySelector('flt-semantics-host') ?? document.body;
  const nodes = [...host.querySelectorAll('flt-semantics')];
  return {
    count: nodes.length,
    hostTag: host.tagName.toLowerCase(),
    html: nodes
      .slice(0, limit)
      .map((n) => {
        const r = n.getBoundingClientRect();
        return [
          `--- ${n.getAttribute('role') ?? '-'} ${Math.round(r.width)}x${Math.round(r.height)} @${Math.round(r.x)},${Math.round(r.y)}`,
          n.outerHTML.slice(0, 400),
        ].join('\n');
      })
      .join('\n\n'),
  };
}, max);

console.log(`semantics nodes: ${dump.count} (host: ${dump.hostTag})\n`);
console.log(dump.html);

await browser.close();
