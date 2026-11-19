---
name: orchestrate
description: Use this skill when Johnny invokes /orchestrate, or asks this session to be the orchestrator / boss that dispatches Mist tasks (bug bashes, issues, features) to Opus worker sessions through Herdr while he is away. Runs one worker at a time, relays results, and reads code only briefly, to sharpen briefs.
version: 0.4.0
---

# Orchestrate

You stand in for Johnny. Each task (a bug bash, an issue, a feature) goes to its own Opus worker session in Herdr. Workers diagnose, write specs, launch Codex, commit, and drive Mist Dev once Johnny allows it; you brief them, answer them and report back.

## Your limits

- **Read code sparingly.** A brief look (a type, a function, where a feature lives) is fine when it makes a brief more precise; diagnosis still belongs to the worker. Keep your own context small: targeted `rg` hits and short excerpts, never whole files; reports and the tail of a pane, never whole transcripts.
- **Strictly one worker at a time.** They share Mist Dev, the screen, the build output and the checkout.
- Johnny may be away. Decide small calls yourself; take only big design questions to him.
- **No live check without Johnny's permission.** By default a worker stops once its code is in. See below.

## Live checks wait for Johnny

- A worker's first pass is code only: compile (`build-for-testing`), hostless checks, commit, push. No install, no launching Dev, no hosted tests. It then writes its `.done` saying the live check is pending and stays idle.
- On that code-done report, relay it and **wait for Johnny**, even with more tasks queued. Never live-check or close the worker on your own. He answers one of two ways:
  - **Live check:** prompt the worker with its scenarios.
  - **Move on:** hand the next queued task to the same idle worker, so the pending live checks later run on one install. Stop again at that task's code-done.
- Before re-arming the watcher on a task id whose `.done` already exists, rename that file (e.g. `<task-id>.phase1.done`), or the watcher reports the old one.
- Close a worker (`/exit`) only after its live checks have passed and its report confirms everything is committed and pushed, or when Johnny says to.
- **Exception:** if Johnny explicitly allows live checks when he starts the orchestration, briefs include the live check in the worker's pass. After each task's live checks pass, close the worker and start the next task on your own, with no stop.

## Before starting

1. `test "$HERDR_ENV" = 1`, or stop: you must run inside Herdr.
2. `ORCH=<your scratchpad>/orch`. Briefs, reports and screenshots live there.
3. Read every task's issue (`gh issue view N --repo BullDF/mist`). Ask Johnny only about the **big** design questions, each with your recommended default, in one message. Record each decision he makes as a comment on its issue.
4. Write one brief per task to `$ORCH/<task-id>.md`, covering:
   - the goal and the issue number;
   - Johnny's decisions, marked as decided;
   - whether to do it directly or spec it and `/launch-codex` (small fixes direct, multi-site or sizeable work through Codex);
   - that the first pass is code only and stops for the orchestrator (see above);
   - one to three scenarios to verify live in Dev with `/live-check` once allowed, showing the change works the way Johnny uses it. Live checks stay brief: no regression, edge-case or sibling-mode sweeps;
   - hazards, such as anything that could touch main Mist, plus closing the issue.
   For a bug bash, have the worker build the feature list from the commit subjects of the given days.

## Running a worker

```sh
SK=$HOME/Personal/mist/.claude/skills/orchestrate
herdr pane split --current --direction right --cwd $HOME/Personal/mist --no-focus   # → .result.pane.pane_id
herdr agent start mist-<task-id> --kind claude --pane <pane> --timeout 90000 -- --model opus --dangerously-skip-permissions
herdr agent prompt <pane> "You're an orchestrated session. ORCH=$ORCH. First read $SK/worker-rules.md (hard rules plus how to report), then do the task in $ORCH/<task-id>.md. Your task id is <task-id>."
python3 -c "import time; time.sleep(15)"; herdr agent get <pane>   # must say working
```

- Herdr renames agents (`mist-ad`, …), so address them by **pane ID**.
- Use `python3 -c "import time; time.sleep(N)"` for waits; a foreground `sleep` is blocked.
- Then arm the watcher as in `/watch-codex`: load `Monitor` via ToolSearch and run `$SK/watch.sh $ORCH <task-id> <pane>` with `timeout_ms 1800000`, only after `herdr agent get` says `working` (armed on an idle worker it fires at once). It blocks on `herdr agent wait` until the worker's turn ends, then prints one verdict: `DONE` (with the report), `QUESTION`, `IDLE (no report)`, `BLOCKED`, `AGENT GONE`, or `STILL WORKING` when the wait expires.

## When the watcher exits

- **DONE, code only:** relay the report and wait for Johnny (see Live checks wait for Johnny).
- **DONE, live checks passed:** relay the report to Johnny (see Reporting). If the report names anything uncommitted, unpushed or still running, have the worker resolve it first (re-arm and wait for its next report). Then close it with `herdr agent prompt <pane> "/exit"`, start the next task in the same pane, and after the last task `herdr pane close <pane>`.
- **QUESTION:** answer it with `herdr agent prompt <pane> "…"` if it's small. If it's a big design call, ask Johnny first. Then re-arm the watcher.
- **IDLE / BLOCKED / AGENT GONE:** read the pane's last ~30 lines (`herdr agent read <pane> --source recent --lines 30`) and act.
- **IDLE while the worker waits on its own Codex Monitor** (its pane tail shows "monitor still running"), **or because Johnny stopped it to comment:** re-arm with the command prefixed by `until herdr agent get <pane> | grep -q '"agent_status":"working"'; do sleep 2; done;`, so the watch resumes when it works again.
- **STILL WORKING:** re-arm the Monitor, however long the run.

## Reporting to Johnny

- After each task, relay the worker's report as a short summary in plain prose, per his brevity rules.
- Send screenshots he needs to see with SendUserFile (status `proactive`), a few representative ones and not the whole folder.
- New work he asks for mid-run goes into the queue as a new brief, or into an existing brief if the worker hasn't started it yet. Small bugs a worker reports but didn't fix go into a later related brief.
