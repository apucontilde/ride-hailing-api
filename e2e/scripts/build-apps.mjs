/**
 * Builds both Flutter web apps against the e2e API.
 *
 * The apps read their API base URL from a compile-time --dart-define
 * (ApiConfig.baseUrl in lib/config.dart), so pointing them at the local
 * e2eserver is a build-time concern, not a runtime one. A release build with
 * the default would target localhost:8080 and every spec would fail on a
 * confusing CORS/connection error instead of a clear assertion failure.
 *
 * Usage: npm run build:apps   (from e2e/)
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const apiUrl = process.env.E2E_API_BASE_URL ?? 'http://127.0.0.1:8099';

// Windows: drive the SDK's .bat through cmd.exe. Everywhere else, call it
// directly.
const isWindows = process.platform === 'win32';
const flutter = isWindows
  ? { cmd: 'cmd.exe', args: ['/c', 'flutter.bat'] }
  : { cmd: 'flutter', args: [] };

const apps = ['driver_app', 'rider_app'];

for (const app of apps) {
  const cwd = join(repoRoot, app);
  const out = join(cwd, 'build', 'web', 'index.html');
  if (!existsSync(join(cwd, 'pubspec.yaml'))) {
    console.error(`skipping ${app}: no pubspec.yaml at ${cwd}`);
    continue;
  }

  console.log(`\n=== building ${app} against ${apiUrl} ===`);
  const res = spawnSync(
    flutter.cmd,
    [...flutter.args, 'build', 'web', '--release', `--dart-define=API_BASE_URL=${apiUrl}`],
    { cwd, stdio: 'inherit', shell: isWindows },
  );
  if (res.status !== 0) {
    console.error(`\n${app} build failed with status ${res.status}`);
    process.exit(res.status ?? 1);
  }
  console.log(`${app} -> ${out}`);
}

console.log('\nboth apps built. run: npm test');
