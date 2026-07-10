# Loop Contract

Task: <one-line goal>
Created: <date>

## Scope

May change:
- <dir/file glob>

Must NOT change:
- test files (unless the task IS writing tests)
- <anything else out of bounds>

## Acceptance criteria (all binary, each with a verify command)

| # | Criterion | Verify command | Pass condition |
|---|-----------|----------------|----------------|
| 1 | All tests pass | `npm test` | exit 0, 0 failed |
| 2 | Types check | `tsc --noEmit` | exit 0 |

## Verify commands

Fast subset (rounds 1..N-1) — these become `.loop/criteria.tsv`
(TAB-separated: `id<TAB>description<TAB>command`; machine-run by the
stop-gate, results land in `.loop/results.json` + `.loop/evidence/`).
Keep this subset FAST: the stop-gate runs it on every stop attempt under an
internal budget (`LOOP_ENG_GATE_TIMEOUT`, default 100s, below the 120s
Stop-hook timeout). A criteria set that overruns the budget is BLOCKED as a
fail-closed timeout — put the slow full suite in the final round, not here:

```
1	All tests pass	npm test
2	Types check	npx tsc --noEmit
```

Full suite (final round):
```
<command>
```

Optional live-app criterion (only when the project already has an e2e
runner and a way to serve the app — verification that drives the running
application catches what unit tests and curl miss):

```
3	Checkout flow works end-to-end	npx playwright test e2e/checkout.spec.ts
```
