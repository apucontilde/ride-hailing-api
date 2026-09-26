/**
 * Shared helpers for the Flutter-web end-to-end suite.
 *
 * ## Why any of this is needed
 *
 * Flutter web renders into a single `<canvas>`. There is no per-widget DOM, so
 * `page.getByText('Accept')` finds nothing. Flutter's answer is its
 * *semantics tree*: activating the hidden `flt-semantics-placeholder` builds a
 * parallel DOM of real, focusable, aria-labelled nodes mirroring the widget
 * tree. Both apps' `web/index.html` auto-click it when loaded with `?e2e=1`.
 *
 * ## What the tree actually looks like (measured, not assumed)
 *
 * Verified against Flutter 3.44.2 with `scripts/dump-semantics-html.mjs`:
 *
 *   - Text fields become a real `<input aria-label="Email">` / `<input
 *     type="password" aria-label="Password">`. These DO use aria-label.
 *   - Buttons become `<flt-semantics role="button" flt-tappable tabindex="0">`
 *     with the visible text as **inner text**, NOT aria-label.
 *   - Plain labels become `<flt-semantics><span>Remember me</span></...>`.
 *   - The Switch becomes `role="checkbox"` with `aria-checked`.
 *
 * So buttons/labels are matched by text and text fields by aria-label. Getting
 * this backwards is why a first attempt at these helpers saw "5 semantics
 * nodes, all with empty labels".
 */

import {
  expect,
  type APIRequestContext,
  type Locator,
  type Page,
} from '@playwright/test';

/** Overridden by env in CI; defaults match cmd/e2eserver's -addr. */
export const API_BASE_URL = process.env.E2E_API_BASE_URL ?? 'http://127.0.0.1:8099';
export const DRIVER_URL = process.env.E2E_DRIVER_URL ?? 'http://127.0.0.1:8091';
export const RIDER_URL = process.env.E2E_RIDER_URL ?? 'http://127.0.0.1:8092';

/**
 * Viewport for both apps.
 *
 * Not the 1280x720 of the `Desktop Edge` device preset: the rider home screen
 * lays its "Request Trip" button out at y≈734, i.e. *below* a 720-tall
 * viewport, so a click at the node's centre landed on nothing and the estimate
 * sheet never opened. 1000px of height keeps the whole request flow on screen.
 */
export const VIEWPORT = { width: 1280, height: 1000 };

/**
 * Wait until Flutter has booted and its semantics tree is live.
 *
 * Two signals, both required: the `flutter-view` host exists, and at least one
 * semantics node is present. Checking only the first would let a spec proceed
 * against an empty tree and fail later with a confusing "element not found".
 */
export async function waitForFlutter(page: Page): Promise<void> {
  await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60_000 });
  await page.waitForSelector('flt-semantics', { state: 'attached', timeout: 60_000 });
}

/** Grant geolocation, pin the position, and load an app with semantics on. */
export async function openApp(
  page: Page,
  baseUrl: string,
  position: { latitude: number; longitude: number },
): Promise<void> {
  await page.context().grantPermissions(['geolocation'], { origin: baseUrl });
  await page.context().setGeolocation(position);
  await page.goto(`${baseUrl}/?e2e=1`);
  await waitForFlutter(page);
}

/**
 * A tappable node whose visible text contains `label`.
 *
 * Matches the semantics node itself, not a descendant, because Flutter often
 * emits a wrapper `<flt-semantics>` around the labelled one.
 */
export function button(page: Page, label: string | RegExp): Locator {
  return page
    .locator('flt-semantics[role="button"]')
    .filter({ hasText: label })
    .first();
}

/**
 * The driver's online/offline Switch.
 *
 * role="switch", not role="checkbox" — the latter is the login screen's
 * "Remember me" checkbox, which is also in the tree on first load.
 */
export function switchToggle(page: Page): Locator {
  return page.locator('flt-semantics[role="switch"]').first();
}

/**
 * Any visible text node containing `label`.
 *
 * Restricted to *leaf* semantics nodes. Flutter emits one node per semantic
 * node and every ancestor aggregates its descendants' text, so a plain
 * `flt-semantics` + hasText match resolves to the root of the tree — which
 * makes an "is this on screen?" assertion pass for anything, and makes
 * `tap()` click the top-left corner (0,0) because that node is full-bleed.
 * `:not(:has(flt-semantics))` keeps only the nodes that actually own the text.
 */
export function text(page: Page, label: string | RegExp): Locator {
  return page
    .locator('flt-semantics:not(:has(flt-semantics))')
    .filter({ hasText: label })
    .first();
}

/**
 * A Flutter text field, matched by the *start* of its aria-label.
 *
 * Flutter's accessible name for a TextFormField varies with focus state: it is
 * just the label ("Email") when the field has content, and label + hint
 * ("Email Enter your email") when empty. An exact match therefore works on one
 * screen and not the next, so match the prefix.
 */
export function field(page: Page, label: string): Locator {
  return page
    .locator(`input[aria-label^="${label}"], textarea[aria-label^="${label}"]`)
    .first();
}

/**
 * Click a semantics node the way a user would.
 *
 * A plain mouse click at the node's centre, rather than `locator.click()`:
 * Flutter listens for pointer events on the canvas and positions its hit
 * testing from the semantics node's box, so a real mouse event is both the
 * most faithful and the least brittle option.
 */
export async function tap(page: Page, target: Locator, timeout = 20_000): Promise<void> {
  await expect(target).toBeVisible({ timeout });
  const box = await target.boundingBox();
  if (!box) {
    throw new Error('semantics node has no bounding box (not laid out)');
  }
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
}

/**
 * Focus a Flutter text field and type into it.
 *
 * Verified and retried: Flutter web keeps a small pool of real `<input>`
 * elements and re-points the `aria-label` at whichever field has focus, so a
 * `fill` can land on an input that is about to be recycled and silently lose
 * the value. Asserting the value actually stuck turns that into a retry rather
 * than a mysterious "Email is required" validation error three steps later.
 */
export async function fill(page: Page, label: string, value: string): Promise<void> {
  let last = '';
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const input = field(page, label);
    await expect(input).toBeVisible({ timeout: 20_000 });
    await input.click();
    await input.fill(value);
    last = await input.inputValue();
    if (last === value) return;
    await page.waitForTimeout(250);
  }
  throw new Error(
    `could not fill "${label}" with "${value}" after 3 attempts (last value: "${last}")`,
  );
}

/** Assert a label is present. */
export async function expectText(page: Page, label: string, timeout = 20_000): Promise<void> {
  await expect(text(page, label)).toBeVisible({ timeout });
}

/**
 * Block until the server has a `driver_positions` row for this driver.
 *
 * Dispatch only finds a driver whose last position is younger than 30 s
 * (`internal/repository/geo_repo.go:73`), and the app creates that row solely by
 * pushing a fix — which it does when the geolocator stream emits, throttled to
 * >=5 s. So "the driver went online" is not the same as "the server knows where
 * they are", and guessing a sleep interval races the 30 s window.
 *
 * Probed over the API rather than through the UI on purpose: the thing being
 * waited for is a server-side side effect of the app, so the assertion reads the
 * server's own state. Uses the driver's own token, obtained by logging in with
 * the same credentials the UI registered.
 */
export async function waitForDriverLocation(
  request: APIRequestContext,
  who: { email: string; phone: string },
  password: string,
  timeout = 30_000,
): Promise<void> {
  const login = await request.post(`${API_BASE_URL}/api/v1/auth/login`, {
    data: { email: who.email, password },
  });
  if (!login.ok()) {
    throw new Error(`probe login failed: ${login.status()} ${await login.text()}`);
  }
  const { access_token: token } = (await login.json()) as { access_token: string };
  const auth = { Authorization: `Bearer ${token}` };

  const me = await request.get(`${API_BASE_URL}/api/v1/driver/me`, { headers: auth });
  if (!me.ok()) throw new Error(`driver/me failed: ${me.status()}`);
  const { driver } = (await me.json()) as { driver: { user_id: string } };

  const deadline = Date.now() + timeout;
  let lastStatus: number | undefined;
  while (Date.now() < deadline) {
    // 404 until the first push lands — that *is* the readiness signal.
    const res = await request.get(`${API_BASE_URL}/api/v1/drivers/${driver.user_id}/location`, {
      headers: auth,
    });
    lastStatus = res.status();
    if (res.ok()) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `no location push reached the server for ${who.email} within ${timeout}ms ` +
      `(last GET /drivers/:id/location status ${lastStatus})`,
  );
}

/** Assert a label is absent (used for "the offer sheet never appeared"). */
export async function expectNoText(page: Page, label: string, timeout = 5_000): Promise<void> {
  await expect(
    page.locator('flt-semantics:not(:has(flt-semantics))').filter({ hasText: label }),
  ).toHaveCount(0, { timeout });
}
