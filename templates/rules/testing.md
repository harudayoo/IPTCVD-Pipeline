---
paths:
  - "{{TEST_GLOB}}"
---

# Testing standards

**Level.** Unit for logic and branches. Integration for boundaries — database,
HTTP, queue. End-to-end only for the critical user path. Do not write an E2E
test for something a unit test can prove.

**Naming.** Test names state the behaviour, not the method: "rejects an
expired token", not "testValidate".

**Isolation.** No network in unit tests. No shared mutable state between
tests. Each test builds and tears down its own fixtures.

**Assertions.** Assert on behaviour and outputs, not on internal call order.
One logical assertion per test where practical.

**Red first.** Every bug fix begins with a test that fails for the reported
reason. Every acceptance criterion has a test that failed before the feature
existed.

**Coverage.** Coverage is a smoke detector, not a goal. An untested branch in
auth, money, or data loss paths is a blocker regardless of the percentage.

The number itself is ratcheted rather than fixed at an aspiration:

```bash
<test command with coverage> | tee coverage.txt
bash .claude/scripts/coverage-gate.sh coverage.txt
```

It fails when coverage drops below the recorded floor, and it *also* fails when
coverage climbs far above it, asking for the floor to be raised. Both directions
matter. A floor that drifts well below reality certifies nothing while still
looking like a gate — which is worse than no gate, because a green check is read
as evidence.

The floor starts unset: the first run reports the real number instead of failing
a build over a figure nobody has seen, and prints the command that arms it. An
unarmed floor exits 0 and emits a CI annotation, because a green job hides
stdout and a gate nobody can see is not a gate.

Lowering the floor to make a build pass is the one move that makes this
worthless. If it is genuinely right, say why in the commit — the point is not
that it is impossible, it is that it is visible.
