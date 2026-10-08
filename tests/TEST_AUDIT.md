# Test Audit

How this repo decides which tests earn their keep, covering **Go (stdlib
`testing`) + Flutter/Dart (`melos`)**. Three modes, one value bar. The executed
results of the current sweep are in [`AUDIT_REPORT.md`](AUDIT_REPORT.md).

Read `AGENTS.md` first. Go: `make test` + `make lint` must stay green. Dart:
`melos run analyze` / `melos run test` must stay green.

## Test surface map

| Surface | Location | Runner | Docker? |
| --- | --- | --- | --- |
| Go unit | `internal/**/*_test.go`, `cmd/**/*_test.go` | `go test ./...` / `make test` | no |
| Go service-level (mock HTTP server) | `tests/**/*_test.go` | `make test` | no |
| Go integration | `*_integration_test.go` (`//go:build integration`) | `make test-integration` | yes |
| Go benchmarks | `*_benchmark_test.go`, `Benchmark*` | `make benchmark` | routing / integration |
| Dart | `shared/test`, `rider_app/test`, `driver_app/test` | `melos run test` | no |
| E2E (out of scope) | `e2e/` (Playwright) | — | yes |

Rules:
- `go test ./...` must never need Docker; DB tests carry `//go:build integration`.
- `tests/` is **service-level mock-backed**, not pure unit (`testutil.NewTestServerE`,
  `db=nil`). Expect mock-oracle risk there.
- A test that passes only without `-race` is a defect. A test whose dependency
  (DB/import) is absent must `t.Skipf`, not `t.Fatalf`.
- Files named `zz_*` are scratch instruments; keep only if a plan cites them as
  evidence, otherwise delete.

## Mode 1 — Authoring gate

Before adding a test, answer four questions; a missing answer means do not add:
1. What observable behavior, invariant, or independent contract does it protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch it? One primary owner per
   contract; another layer needs its own distinct risk (transport, lifecycle,
   serialization). Prefer a new `t.Run`/`group` case over a near-duplicate.
4. Does it need a production seam no production caller needs? If yes, move the
   test to the real boundary.

Then check every junk pattern; a match fails the gate unless the retention bar
names the contract it guards. A test that breaks under a behavior-preserving
refactor is asserting implementation.

## Mode 2 — Audit

Read-only first. For each candidate record `test name + file:line`, what it can
detect, non-test callers of the covered seam, the stronger remaining proof, and
the focused command. Classify **DELETE / CONSOLIDATE / FIX / KEEP**. Prefer
net-negative LOC; never add a replacement that restates the same implementation.
If a removed test is cited in a domain `STATUS.md`, update that entry.

## Mode 3 — Domain sweep

Prune one surface at a time (`tests/`, `internal/repository`, `shared/test`, …).
Sequence: `docs → approved deletions → verification`. Re-run read-only discovery
after each landed batch; do not start a second sweep in the same change.

## Junk patterns

- assertion-free probes (only `t.Log`/`print`; branches that cannot fail);
- self-comparisons/identity copiers (`Route` vs `RouteWithWeights{}` when the
  former delegates to the latter);
- copied fixtures/inventories/export lists; exact string/source greps;
- duplicate invocations of one contract at one layer;
- provider-local replays of shared helpers (a local `parseJSON`/`contains`);
- tests preserving test-only exports/globals/wrappers; dead code only tests call;
- expected values produced by the helper/mock under test (an oracle recomputed
  with the production formula, or a mock's literal like `5000`/`454`);
- one identical mock standing in for different APIs; fakes that reimplement the
  behavior they are used to assert;
- capability tests restating declared flags/values;
- negative controls that pass for an unrelated reason;
- names promising more than the input exercises (a "pagination" test that never
  requests page 2; a "long enough to scroll" test fed two items).

Dart/Flutter additions: existence-only smokes (`find.byType(Scaffold)`); the
same; tautological getter checks (`item.icon == item.destination.icon`); app-local
replays of a `shared/` widget suite; expected labels from the production
formatter; placeholder `expect(true, isTrue)`.

## Retention bar

Keep a test enforcing a public API, protocol, config, migration, storage,
security, platform, default, generated cross-language, or architecture contract;
observable call ordering; or a credible regression. Also keep a retained
test that fails on baseline (treat as a product bug). Static or slow is not a
deletion reason. A test that resembles implementation may still be the
independent contract — prove otherwise before removing.

## Go best practices

- table-driven `t.Run`; collapse near-identical tests;
- `t.Parallel()` only where no `t.Setenv`/shared global forbids it;
- helpers take `t` and call `t.Helper()`; prefer `t.Cleanup` over `defer`;
- one assertion library per package (this repo mixes stdlib and `testify`);
- race-safe: anything shared must pass `go test -race`; mocks copy, never alias;
- no test-only production seams — delete/quarantine or document;
- DB-free default; `t.Skipf` when the DB/import is absent;
- shared fixtures over copied DDL; `testdata/` for binary/string fixtures;
- independent oracles; honest names; check errors used to build state.

## Dart / Flutter best practices

- behavior over existence; existence-only only when presence is the contract;
- find by `Key`/semantics/public contract, not positional `find.byType(...).at(i)`;
- shared widgets are owned in `shared/test`; apps test only their own wiring;
- `addTearDown(container.dispose)`/`router.dispose`; cancel timers/subscriptions;
- no real sleeps: `pump`/`pumpAndSettle` + injected clocks/`fakeAsync`; never
  `pumpAndSettle` across an infinite animation; no callbacks in `pump()` (use
  `pumpAndSettle`/`tester.runAsync` for async work);
- proportionate mocks; reset hard-coded viewports in teardown;
- honest names; goldens opt-in only.

## Validation commands

```bash
go test -count=1 ./...                       # unit + service-level, no DB
make lint                                    # golangci-lint v2, 0 issues
go test -race ./tests/                       # race safety
make test-integration                        # DB-backed
export PATH=~/fvm/default/bin:$PATH
melos run analyze && melos run test          # all Dart packages
```
