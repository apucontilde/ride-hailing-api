/**
 * Playwright config for the Flutter-web end-to-end suite.
 *
 * Three servers come up automatically:
 *   1. cmd/e2eserver  — the real API on :8099, strict in-memory repos
 *   2. driver_app web — static files on :8091
 *   3. rider_app  web — static files on :8092
 *
 * The two apps are served from *different origins* on purpose. Both store
 * their auth token in localStorage under the same key, so sharing an origin
 * would mean the driver app's session overwrote the rider's and vice versa —
 * exactly the kind of cross-contamination that makes browser suites lie.
 *
 * Web builds must exist before the static servers start. `make e2e-build`
 * (or `npm run build` here) produces them; see e2e/README.md.
 */

import { defineConfig, devices } from '@playwright/test';

const API_PORT = 8099;
const DRIVER_PORT = 8091;
const RIDER_PORT = 8092;

const API_URL = `http://127.0.0.1:${API_PORT}`;
const DRIVER_URL = `http://127.0.0.1:${DRIVER_PORT}`;
const RIDER_URL = `http://127.0.0.1:${RIDER_PORT}`;

const REPO_ROOT = '..';

export default defineConfig({
  testDir: './specs',
  // Dispatch offers are time-sensitive (the server holds an offer open for
  // 30s) and the UI waits on real WebSocket delivery, so give each spec room
  // without hiding a genuine hang. The budget covers: two app boots, a signup
  // form, the >=5s location throttle, and a ride request.
  timeout: 240_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  // The e2eserver keeps in-memory state, and these specs create real users on
  // it. One worker keeps runs deterministic; parallelism would need a
  // per-worker server.
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : [['list']],

  use: {
    baseURL: DRIVER_URL,
    // See VIEWPORT in helpers.ts: the rider's "Request Trip" button falls below
    // a 720-tall viewport, so the preset height is not usable here.
    viewport: { width: 1280, height: 1000 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    {
      name: 'edge',
      use: {
        ...devices['Desktop Edge'],
        // Use the Edge already installed on the machine rather than
        // downloading Playwright's own Chromium — matches the "runs on
        // web(edge)" requirement and keeps the install small.
        channel: 'msedge',
        launchOptions: {
          args: ['--disable-features=IsolateOrigins,site-per-process'],
        },
      },
    },
  ],

  webServer: [
    {
      command: `go run ./cmd/e2eserver -addr :${API_PORT}`,
      cwd: REPO_ROOT,
      url: `${API_URL}/health`,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
      stdout: 'pipe',
      stderr: 'pipe',
    },
    {
      command: `npx http-server ../driver_app/build/web -p ${DRIVER_PORT} -c-1 --silent`,
      url: DRIVER_URL,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
    },
    {
      command: `npx http-server ../rider_app/build/web -p ${RIDER_PORT} -c-1 --silent`,
      url: RIDER_URL,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
    },
  ],
});

export { API_URL, DRIVER_URL, RIDER_URL };
