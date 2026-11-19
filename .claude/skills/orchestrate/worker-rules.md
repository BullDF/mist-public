# Rules for orchestrated Mist sessions

Johnny may be away, or using the screen. An orchestrator (another Claude session standing in for him) runs Opus sessions like you **one at a time**. No other session uses Mist Dev or the build while you run. Never wait on Johnny. `ORCH` (the orchestrator's folder for briefs and reports) is given in your prompt.

## Hard rules

1. **Code first, live check only when told.**
   - Your first pass is code only, unless your brief says the live check is already allowed. Verify with `build-for-testing` and hostless `build-scripts/test-*.sh` checks, commit and push. Don't install, launch Dev or run hosted tests.
   - Then report (below) with the live check marked pending, and stay idle. The orchestrator prompts you for the live check or hands you the next task.
   - When told to, verify with `/live-check`, briefly: only that what you changed works, with the brief's scenarios and nothing extra. Its hard rules bind you for the whole task, not only during a check: Mist Dev only, never main Mist, harmless testing, refocus Ghostty, leave Dev as you found it.
2. **Codex does code edits only**, plus compiling, hostless `build-scripts/test-*.sh` checks and its commits. Every spec must say that Codex never:
   - launches Mist or any browser;
   - runs `install.sh` or hosted tests (`mist/scripts/test.sh`);
   - drives UI.

   You do all installs, hosted tests and live driving of Dev yourself.
3. Commit straight to `main` per CLAUDE.md (one concise line). Pushing to `origin` is fine; never force-push.
4. Launch Codex only with `/launch-codex` (the codex tab of your own Herdr workspace). Don't touch other workspaces' panes or agents, or the orchestrator's pane.
5. **Small calls and small bugs are yours.**
   - Decide small calls yourself.
   - Fix small bugs you find along the way, even outside your task, each in its own commit, and verify each in the live check.
   - A mismatch your change creates or exposes (wording, styling or behavior that differs between sibling modes or views) is a bug, not a call: fix it, never list it for Johnny.
   - Open a GitHub issue on `BullDF/mist` only for a big bug or a big design question.
   - List design questions in your final report for Johnny.
6. No AskUserQuestion.
7. Never put `rm` in a compound Bash command (`…; rm -f x`, `&& rm`): Claude Code's dangerous-rm check prompts even under bypass permissions, and the unattended prompt blocks you. Write scratch files into your scratchpad and leave them, or run `rm` alone on a literal path.

## Talking to the orchestrator

- **Blocked on a decision you can't make:** write the question (short) to `$ORCH/<task-id>.question`, then end your turn. The answer arrives as a prompt in your pane. Delete the file when you resume.
- **Finished (code pass or live check):** write the report to `$ORCH/<task-id>.done`, then end your turn. Keep it brief:
  - what you verified, and whether the live check is still pending;
  - what you fixed (commit subjects);
  - issues opened or closed;
  - calls Johnny may want to revisit, and design questions;
  - anything still failing;
  - that everything is committed and pushed, or what isn't, and anything still running.

  Put screenshots meant for Johnny under `$ORCH/screens/`. The orchestrator closes you with `/exit` once your report confirms nothing is left uncommitted, unpushed or running.
