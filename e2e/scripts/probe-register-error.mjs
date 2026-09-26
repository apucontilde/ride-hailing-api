/**
 * Proves the register screen shows the backend's message, not Dio's verbose
 * `DioException.message`.
 *
 * Registers a user over the API, then submits the *same* email through the real
 * register form and prints the resulting on-screen error text.
 *
 * Usage: node scripts/probe-register-error.mjs [riderUrl] [apiBase]
 */

import { chromium } from '@playwright/test';

const url = process.argv[2] ?? 'http://127.0.0.1:8092';
const api = process.argv[3] ?? 'http://127.0.0.1:8099';

const email = `dup.${Date.now()}@test.com`;
const phone = `+1${String(Date.now() * 100 + 7).slice(-10)}`;

const created = await fetch(`${api}/api/v1/auth/register`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, phone, password: 'SecurePass1' }),
});
console.log(`seed register -> ${created.status}`);

const browser = await chromium.launch({ channel: 'msedge', headless: true });
const ctx = await browser.newContext({
  permissions: ['geolocation'],
  geolocation: { latitude: 40.7128, longitude: -74.006 },
  viewport: { width: 1280, height: 1000 },
  locale: 'en-US',
});
const page = await ctx.newPage();

const leafText = async () =>
  page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics:not(:has(flt-semantics))')]
      .map((el) => (el.textContent ?? '').trim())
      .filter((t) => t && t !== 'Sign Up' && t !== 'Already have an account? Log in'),
  );

const tap = async (selector, note) => {
  const loc = page.locator(selector).filter({ hasText: note }).first();
  const box = await loc.boundingBox();
  if (!box) throw new Error(`could not resolve ${note}`);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
};

await page.goto(`${url}/?e2e=1`);
await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60_000 });
await page.waitForTimeout(5000);

await tap('flt-semantics[role="button"]:not(:has(flt-semantics))', "Don't have an account? Sign up");
await page.waitForTimeout(2000);

const set = async (label, value) => {
  // Verified + retried, like helpers.ts `fill`: Flutter recycles a pool of
  // real <input> elements and re-points aria-label at the focused field, so a
  // fill can land on an input that is about to be reused and silently lost.
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const f = page.locator(`input[aria-label^="${label}"]`).first();
    await f.waitFor({ state: 'visible', timeout: 20_000 });
    await f.click();
    await f.fill(value);
    if ((await f.inputValue()) === value) return;
    await page.waitForTimeout(250);
  }
  throw new Error(`could not fill ${label}`);
};
await set('Email', email);
await set('Phone', phone);
await set('Password', 'SecurePass1');

await tap('flt-semantics[role="button"]:not(:has(flt-semantics))', 'Sign Up');
await page.waitForTimeout(5000);

const text = await leafText();
console.log('\non-screen text after a duplicate-email submit:');
for (const t of text) console.log(`  ${JSON.stringify(t)}`);

const raw = text.find((t) => t.includes('This exception was thrown') || t.includes('developer.mozilla.org'));
console.log(raw ? '\nFAIL: raw Dio text leaked into the UI' : '\nOK: no raw Dio text on screen');

await page.screenshot({ path: 'test-results/probe-register-error.png' });
await browser.close();
