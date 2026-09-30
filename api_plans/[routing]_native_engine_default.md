---
tag: routing
depends_on: []
status: open
---

# Record `native` as the permanent routing-engine default

Bug #1 is **decided, not fixed by code**: `ROUTING_ENGINE` defaulting to `native` is intentional.
The in-process A* engine is ~28,000× faster than `pgr_dijkstra` on the plan-03 `hop` workset, and
pgRouting is not worth tuning at this scale. `pgrouting` stays as an opt-in engine for
parity/validation and as the extension-absent fallback target. This plan only makes the codebase
say so, then closes the bug.

**Read first:**

- `internal/config/config.go:40-47,118,169-178` — `RoutingEngine` field, its comment, and
  `routingEngineFromEnv` (already defaults to `native`; keep it).
- `internal/repository/pgrouting_repo.go:99-132` — the factory: `pgrouting` is built only when
  requested AND the extension is present, else it logs and falls back to native.
- `internal/repository/pgrouting_repo_benchmark_test.go:135-164` and `internal/routing/benchmark_test.go`
  — the `corner`/`hop` benchmarks behind the ~28,000× ratio.
- `AGENTS.md` → "Environment facts" fact 3 (`ROUTING_ENGINE` defaults to `native` because the
  benchmark gate kept it).

## Decision (taken)

`native` is the production default permanently. `pgrouting` is opt-in for parity work. No engine
swap is planned; the benchmark gate is not going to be re-opened.

## Work

1. Make the intent explicit in code/docs so a future reader cannot mistake it for an unresolved
   gate:
   - `internal/config/config.go`: adjust the `RoutingEngine` comment to say native is the
     intended default and why (in-memory A* at this scale), not "pending a gate".
   - `internal/repository/pgrouting_repo.go`: if any comment still frames the default as
     provisional, align it with the decision.
   - `AGENTS.md` fact 3 and the routing-env paragraph: state native is the deliberate default;
     pgrouting opt-in.
2. Record the benchmark evidence (the `corner`/`hop` native vs pgRouting numbers) in
   `api_plans/STATUS.md` so the ratio lives next to the decision.
3. Close bug #1 (remove the row once the docs above are in).

## Tests

- No behavior change. `routingEngineFromEnv` already whitelists `native|pgrouting` and defaults to
  `native`; if a config test does not already pin that default, add one.

## Accept

- The default is documented as intentional in the config comment, `pgrouting_repo.go`, and
  `AGENTS.md`; the benchmark ratio is in `STATUS.md`; bug #1 is closed.

## Verify

```bash
go test -count=1 ./internal/config/ ./internal/repository/
make test && make lint
make benchmark && make bench-integration   # numbers recorded, not gated
```
