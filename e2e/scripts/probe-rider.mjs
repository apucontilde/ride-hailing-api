/**
 * Walks the rider flow step by step, dumping the semantics tree at each stop.
 *
 * Diagnostic companion to the specs: when a rider-flow locator fails, run this
 * to see which screen you are actually on instead of guessing from a trace.
 *
 * Usage: node scripts/probe-rider.mjs [riderUrl]
 */

import { chromium } from '@playwright/test';

const url = process.argv[2] ?? 'http://127.0.0.1:8092';

const browser = await chromium.launch({ channel: 'msedge', headless: true });
const ctx = await browser.newContext({
  permissions: ['geolocation'],
  geolocation: { latitude: 40.7128, longitude: -74.006 },
  locale: 'en-US',
});
const page = await ctx.newPage();
page.on('pageerror', (e) => console.log(`  [pageerror] ${e.message}`));
page.on('console', (m) => {
  if (m.type() === 'error') console.log(`  [console.error] ${m.text().slice(0, 200)}`);
});

async function dump(label) {
  const nodes = await page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics:not(:has(flt-semantics))')]
      .map((el) => {
        const r = el.getBoundingClientRect();
        return {
          role: el.getAttribute('role') ?? '-',
          text: (el.textContent ?? '').trim().slice(0, 40),
          label: el.getAttribute('aria-label') ?? '',
          w: Math.round(r.width),
          h: Math.round(r.height),
        };
      })
      .filter((n) => n.text || n.label),
  );
  console.log(`\n--- ${label} (${nodes.length} nodes) ---`);
  for (const n of nodes) {
    const size = n.w && n.h ? `${n.w}x${n.h}` : 'zero';
    console.log(`  [${n.role}] ${size} ${JSON.stringify(n.label || n.text)}`);
  }
}

async function tapText(re, note, role) {
  // Leaf nodes only: an ancestor flt-semantics aggregates all descendant text,
  // so an unrestricted match resolves to the full-bleed root and clicks (0,0).
  // `role` matters too: the register screen's appBar is a leaf reading "Sign Up"
  // and comes before the real submit button in DOM order.
  const sel = role
    ? `flt-semantics[role="${role}"]:not(:has(flt-semantics))`
    : 'flt-semantics:not(:has(flt-semantics))';
  const loc = page.locator(sel).filter({ hasText: re }).first();
  const box = await loc.boundingBox();
  if (!box) {
    console.log(`  !! could not resolve ${note ?? re}`);
    return false;
  }
  console.log(`  -> tap ${note ?? re} at ${Math.round(box.x)},${Math.round(box.y)}`);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  return true;
}

await page.goto(`${url}/?e2e=1`);
await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60_000 });
await page.waitForTimeout(6000);
await dump('after boot');

const ts = Date.now();
const email = `probe.rider.${ts}@test.com`;
const phone = `+1${String(ts * 100 + 1).slice(-10)}`;

await tapText("Don't have an account? Sign up", 'go to register');
await page.waitForTimeout(2000);
await dump('register screen');

const setField = async (label, value) => {
  const f = page.locator(`input[aria-label^="${label}"]`).first();
  await f.click();
  await f.fill(value);
};
await setField('Email', email);
await setField('Phone', phone);
await setField('Password', 'SecurePass1');
await dump('register filled');

await tapText('Sign Up', 'submit register', 'button');
await page.waitForTimeout(6000);
await dump('after register (expect home map)');

await tapText('Where to?', 'destination field');
await page.waitForTimeout(3000);
await dump('after tapping Where to?');

const inputs = await page.locator('input, textarea').count();
console.log(`\ninput/textarea count: ${inputs}`);
for (let i = 0; i < inputs; i += 1) {
  const info = await page.locator('input, textarea').nth(i).evaluate((el) => ({
    tag: el.tagName.toLowerCase(),
    label: el.getAttribute('aria-label'),
    placeholder: el.getAttribute('placeholder'),
    visible: el.getBoundingClientRect().width > 0,
  }));
  console.log(`  [${i}] ${JSON.stringify(info)}`);
}

const search = page.locator('input[aria-label^="Where to?"]').first();
await search.click();
await search.fill('E2E');
await page.waitForTimeout(4000);
await dump('after typing E2E (expect results)');

await tapText('E2E Destination Plaza', 'pick result');
await page.waitForTimeout(3000);
await dump('after picking result (expect home w/ destination)');

const req = page.locator('flt-semantics[role="button"]').filter({ hasText: 'Request Trip' }).first();
const reqBox = await req.boundingBox();
console.log(`\nRequest Trip box: ${JSON.stringify(reqBox)}`);
if (reqBox) {
  console.log(`  -> tapping centre ${Math.round(reqBox.x + reqBox.width / 2)},${Math.round(reqBox.y + reqBox.height / 2)}`);
  await page.mouse.click(reqBox.x + reqBox.width / 2, reqBox.y + reqBox.height / 2);
}
await page.waitForTimeout(6000);
await dump('after Request Trip (expect estimate sheet)');

await page.screenshot({ path: 'test-results/probe-rider.png' });
console.log('\nscreenshot -> test-results/probe-rider.png');

await browser.close();
