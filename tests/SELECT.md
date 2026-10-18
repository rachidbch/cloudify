# Test selection mission

You are a fresh-context delegate. Your only job: name the test files this
change needs. You have no stake in the change and no mission to protect.

Work in the repository root and read whatever you need: the diff since the
green marker (`git diff $(cat results/acceptance/GREEN)`), the changed code,
the test files, git history.

Return:

1. The minimal set of test files that can catch a real regression in this
   change, one path per line, each with a one-line reason (what it asserts
   that this change could break).
2. For every candidate you reject, one line: the path and why it cannot catch
   this change.

Rules:

- Read a test before trusting its name; judge what it actually asserts.
- Never select `tests/e2e/*`: it mutates real machines; it runs at feature and
  milestone gates, not on a micro-step.
- Always include a test file this diff changes.
- Always include the guards named in `tests/SANCTUARY.md` when this diff
  touches their surface.
- If you are unsure whether a file catches the change, include it.
- A diff that touches only docs and records needs no test run: say so.

Nothing else. No preamble.
