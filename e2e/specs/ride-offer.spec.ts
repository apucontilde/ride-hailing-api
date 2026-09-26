/**
 * End-to-end: "rider requests a ride, the driver sees the offer".
 *
 * This is the story reported broken — a rider books, and the driver's app never
 * shows an offer. It drives both real UIs in Edge against the real API
 * (cmd/e2eserver, strict in-memory repos) and asserts the driver's OfferSheet
 * actually appears.
 *
 * Why this could not be caught before:
 *  - The Go harness fabricated a "simulated-driver" whenever no real driver was
 *    online, so dispatch always succeeded.
 *  - The Flutter widget tests inject `ride.offer` straight into the notifier, so
 *    they prove the reaction to an offer but never that one is produced and
 *    delivered.
 *
 * Only a real browser against a real server closes that gap.
 */

import { expect, test, type Page } from '@playwright/test';
import {
  DRIVER_URL,
  RIDER_URL,
  button,
  expectNoText,
  expectText,
  field,
  fill,
  openApp,
  switchToggle,
  tap,
  text,
  waitForFlutter,
  VIEWPORT,
} from '../helpers';

/** The rider's pickup, and the driver's spot ~20 m away. */
const PICKUP = { latitude: 40.7128, longitude: -74.006 };
const DRIVER_SPOT = { latitude: 40.713, longitude: -74.006 };
const PASSWORD = 'SecurePass1';

// A fresh id per *run*, not per process: cmd/e2eserver keeps in-memory users
// and `reuseExistingServer` means a second `npm test` hits the same server, so
// a process-local counter alone would collide and get a 409 on register.
//
// The phone must stay all-digits (Validators.validatePhone rejects anything
// else), so the run id is numeric — a base36 id produced "+1muhtvb3n2..." and
// the form rejected it before the request was ever sent.
const RUN_MS = Date.now();
let seq = 0;
function uniq(prefix: string): { email: string; phone: string } {
  seq += 1;
  // Last 10 digits of (ms * 100 + seq) = a plausible NANP number, unique per
  // run and across the handful of users a run creates.
  const digits = String(RUN_MS * 100 + seq).slice(-10);
  return {
    email: `e2e.${prefix}.${RUN_MS}.${seq}@test.com`,
    phone: `+1${digits}`,
  };
}

/** Register + become a driver, leaving the app on the home screen, offline. */
async function signUpDriver(page: Page, who: { email: string; phone: string }): Promise<void> {
  await tap(page, button(page, 'Sign up')); // from the login screen
  await expectText(page, 'Drive With Us');
  await fill(page, 'Email', who.email);
  await fill(page, 'Phone', who.phone);
  await fill(page, 'Password', PASSWORD);
  await tap(page, button(page, 'Sign Up'));

  await expectText(page, 'Become a Driver');
  await fill(page, 'First name', 'E2E');
  await fill(page, 'Last name', 'Driver');
  await tap(page, button(page, 'Register as a driver'));

  await expectText(page, 'Offline');
}

/**
 * Register the rider (the app boots to /login, so the account has to be created
 * before it can request a ride) and land on the home map.
 */
async function signUpRider(page: Page, who: { email: string; phone: string }): Promise<void> {
  await tap(page, button(page, "Don't have an account? Sign up"));
  // The register screen's appBar title *and* its submit button both read
  // "Sign Up", so assert on the Phone field instead to prove we got there.
  await expect(field(page, 'Phone')).toBeVisible({ timeout: 20_000 });
  await fill(page, 'Email', who.email);
  await fill(page, 'Phone', who.phone);
  await fill(page, 'Password', PASSWORD);
  await tap(page, button(page, 'Sign Up'));

  await expectText(page, 'Where to?', 30_000);
}

/**
 * Pick a destination from the seeded places, then request the trip.
 *
 * The home map exposes three buttons — "Current location", "Where to?" and
 * "Request Trip" — and the estimate sheet only appears after "Request Trip",
 * not on selecting the destination.
 */
async function requestRide(page: Page): Promise<void> {
  await tap(page, button(page, 'Where to?'));

  // The search screen replaces the field with a real <input> carrying the same
  // "Where to?" accessible name.
  const search = field(page, 'Where to?');
  await expect(search).toBeVisible({ timeout: 20_000 });
  await search.fill('E2E');

  await expectText(page, 'E2E Destination Plaza');
  await tap(page, text(page, 'E2E Destination Plaza'));

  await tap(page, button(page, 'Request Trip'));
  await expectText(page, 'Choose a ride', 30_000);
  await tap(page, button(page, 'Confirm Ride'));
}

test.describe('US-D5 / US-D6 — rider requests a ride, driver sees the offer', () => {
  test('the offer sheet reaches the driver', async ({ browser }) => {
    const rider = uniq('rider');
    const driver = uniq('driver');

    // --- Driver: sign up, go online ---------------------------------------
    const driverCtx = await browser.newContext({
      permissions: ['geolocation'],
      geolocation: DRIVER_SPOT,
      viewport: VIEWPORT,
      locale: 'en-US',
    });
    const driverPage = await driverCtx.newPage();
    await driverPage.goto(`${DRIVER_URL}/?e2e=1`);
    await waitForFlutter(driverPage);
    await signUpDriver(driverPage, driver);

    await tap(driverPage, switchToggle(driverPage));
    await expectText(driverPage, 'Online', 30_000);

    // LocationService pushes a fix only when the geolocator stream emits, and
    // throttles to >=5s. Nudge the position so a fix is guaranteed, then wait
    // out the throttle — this is the step the original bug report hinged on.
    await driverCtx.setGeolocation({
      latitude: DRIVER_SPOT.latitude + 0.0001,
      longitude: DRIVER_SPOT.longitude,
    });
    await driverPage.waitForTimeout(9000);

    // --- Rider: request a ride -------------------------------------------
    const riderCtx = await browser.newContext({
      permissions: ['geolocation'],
      geolocation: PICKUP,
      viewport: VIEWPORT,
      locale: 'en-US',
    });
    const riderPage = await riderCtx.newPage();
    await riderPage.goto(`${RIDER_URL}/?e2e=1`);
    await waitForFlutter(riderPage);
    await signUpRider(riderPage, rider);
    await requestRide(riderPage);

    // --- The assertion ----------------------------------------------------
    // The offer must surface as a real sheet, with the ride's details loaded
    // and both decisions live inside the server's 30s window.
    await expectText(driverPage, 'New Ride Offer', 45_000);
    await expectText(driverPage, 'Pickup');
    await expectText(driverPage, 'Dropoff');
    await expectText(driverPage, 'Fare');
    expect(await button(driverPage, 'Accept').isVisible()).toBe(true);
    expect(await button(driverPage, 'Decline').isVisible()).toBe(true);

    // The rider was moved to the matching screen, not an error.
    await riderPage.waitForTimeout(3000);
    await expect(
      riderPage.locator('flt-semantics').filter({ hasText: /driver|matching|Driver/ }).first(),
    ).toBeVisible({ timeout: 20_000 });

    await driverCtx.close();
    await riderCtx.close();
  });

  test('a driver whose location never pushed receives no offer', async ({ browser }) => {
    // The regression guard. A driver who is online but whose geolocation never
    // produced a fix has no driver_positions row, so dispatch cannot find them
    // and the rider is told nobody is available. The driver's screen must stay
    // empty — this is the exact shape of the reported bug.
    const rider = uniq('rider2');
    const driver = uniq('driver2');

    // No geolocation permission at all.
    const driverCtx = await browser.newContext({ permissions: [], locale: 'en-US', viewport: VIEWPORT });
    const driverPage = await driverCtx.newPage();
    await driverPage.goto(`${DRIVER_URL}/?e2e=1`);
    await waitForFlutter(driverPage);
    await signUpDriver(driverPage, driver);

    await tap(driverPage, switchToggle(driverPage));
    await expectText(driverPage, 'Online', 30_000);

    const riderCtx = await browser.newContext({
      permissions: ['geolocation'],
      geolocation: PICKUP,
      viewport: VIEWPORT,
      locale: 'en-US',
    });
    const riderPage = await riderCtx.newPage();
    await riderPage.goto(`${RIDER_URL}/?e2e=1`);
    await waitForFlutter(riderPage);
    await signUpRider(riderPage, rider);
    await requestRide(riderPage);

    // Give dispatch time to search and give up.
    await riderPage.waitForTimeout(6000);

    // No offer sheet, ever.
    await expectNoText(driverPage, 'New Ride Offer', 10_000);
    // The driver still believes they are waiting for offers — the silent
    // failure the bug report describes.
    await expectText(driverPage, "You're online");
  });
});
