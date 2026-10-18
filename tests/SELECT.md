# Test selection mission

Your only job: name the test files this change needs. Read the diff since the
green marker (`git diff $(cat results/acceptance/GREEN)`), the changed code, the test files themselves
and git history; judge what a test asserts, never its name.

Rules:

- Select the minimal set that can catch a real regression in this change.
- Always select a test file this diff changes.
- Always select the guards in `tests/SANCTUARY.md` when the diff touches their surface.
- Never select `tests/e2e/*`: it mutates real machines; feature and milestone gates only.
- If unsure whether a file catches the change, select it.
- A docs-and-records-only diff needs no run: say so.

Output: one PICK line per selected file (path, what it asserts that this change
could break), one DROP line per rejected candidate (path, why it cannot). No
preamble, no commentary.
