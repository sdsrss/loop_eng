# Loop State

Handoff notes for a human and for the next fresh session. **Nothing reads this
file mechanically** — no hook, no script, no gate. It is prose, and the
`Status:` line below is prose too: the machine answer to "is this loop done"
lives in `.loop/results.json` (`all_green`) and in the ticked boxes of
`.loop/backlog.md`, both written by `run-contract.sh` from real exit statuses.
Write `Status:` for the reader; never cite it as evidence, and if it ever
disagrees with the ledger, the ledger is right and this file is stale.

Task: <one-line goal>
Status (advisory): running | ALL GREEN | stopped (rule N)

## Deferred (not loopable)

<item — reason: needs-human / interactive / no-machine-verify / out-of-repo-scope>

## Rounds

### Cycle 1/5
- Changed: <files + one-line what>
- Commit: <hash>
- Check result: <ALL GREEN | FAILED: n failures>
- Next: <one line>

### Cycle 2/5
...
