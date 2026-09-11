---
paths:
  - "{{BACKEND_GLOB}}"
---

# Backend standards

**Size.** 800 lines is the bar for a source file, and it is measured, not
suggested: `bash .claude/scripts/ratchet.sh` runs in CI. It is a ratchet, so a
tree already over the bar is recordable — a baselined file may shrink and may
never grow, and an unlisted file may not cross at all. `--list` shows every
file currently over it, largest first.

Lines are what the ratchet counts, and only lines. Function length, nesting
depth and parameter counts need a real parser per language to measure honestly,
so they stay below as stated standards that review checks by reading. Treating
the ratchet's silence as approval of a 300-line function is reading it
backwards.

Size is a proxy, and the reason it is worth measuring is that nobody refactors a
file they cannot hold in their head, so defects pool where the lines do: on the
codebase this pipeline came from, 28 of 30 react-hooks violations lived in one
1,476-line file.

**Boundaries.** Controllers and route handlers stay thin: validate, delegate,
respond. Business logic lives in the service/domain layer. No queries in
controllers.

**Validation.** Validate at the boundary, once, with an explicit schema.
Never trust a value that crossed a process or network edge.

**Errors.** One error envelope shape for the whole API. Never leak stack
traces, SQL, or internal paths to a client. Log the cause, return a code.

**Transactions.** Any multi-write operation is transactional. State the
isolation assumption in a comment where it matters.

**Data access.** Parameterised queries only. Eager-load relations that a loop
will touch — an N+1 in a request path is a defect, not a nit.

**Logging.** Structured. No PII, tokens, or secrets in log lines, ever.

**Idempotency.** Anything a client can retry must be safe to retry.

**Async work.** Anything that sends an email/SMS/push notification or does
bulk processing is queued, not run inline in the request cycle — a slow
third-party call in a request handler is a defect, not a nit, once it can be
queued instead.
