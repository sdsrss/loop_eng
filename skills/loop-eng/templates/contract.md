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

Fast subset (rounds 1..N-1):
```
<command>
```

Full suite (final round):
```
<command>
```
