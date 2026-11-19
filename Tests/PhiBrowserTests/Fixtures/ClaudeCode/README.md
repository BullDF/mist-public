Recorded with Claude Code 2.1.310 on October 25, 2026, using Sonnet, low effort,
manual permissions, and a fresh temporary working directory for each session.
Each file contains real stdout JSONL. Temporary paths are `/tmp/mist-fixture`;
installation metadata, token accounting, and opaque thinking signatures are omitted.

- `text`: asked for “Mist fixture ready.” with no tools.
- `permission`: asked Bash to run `touch b.txt`; the recorder allowed its stdio
  permission request using the unchanged input object.
- `image`: supplied a generated 32 × 32 red PNG as a base64 image block and asked
  for its color. Claude answered “Red”.
- `interrupt`: requested an 8,000-word lighthouse story and sent an interrupt
  immediately after the first text delta. Some already-buffered deltas followed.
  The CLI acknowledged with `still_queued: []`, emitted an aborted assistant text
  block and a user interruption echo, then returned `error_during_execution` with
  `terminal_reason: aborted_streaming`. After stdin closed it exited with code 1.

Protocol observations: manual mode reports `permissionMode: default`; completed
assistant envelopes contain individual blocks sharing an API message id, rather
than necessarily the whole message. Thinking can have empty text and separate
estimated-token status events. Tests preserve the streamed item identities when
the corresponding authoritative blocks arrive.

`ask.jsonl` and `plan.jsonl` were recorded with Claude Code 2.1.310 on October 25,
2026, launching with `--model haiku --effort low`, stream-json input/output,
partial messages, and `--permission-prompt-tool stdio` in fresh temporary folders.
Paths are normalized to `/tmp/mist-fixture`; installation metadata, opaque thinking
signatures, API request IDs, and token/cost accounting are omitted. Permission
request IDs and tool-use IDs remain for replay. Streaming event order is preserved;
partial-JSON chunk boundaries shift where a normalized path is shorter.

- `ask`: bypass permissions; requested one single-select color question and one
  multi-select features question in the same AskUserQuestion call. The recorder
  allowed with the original input plus `answers`: `Pick a color` → `Blue`,
  `Pick features` → `Fast, Quiet`. This still prompted in bypass mode and carried
  `requires_user_interaction: true`. Its `tool_use_result` contains both
  `questions` and `answers`; its text quotes each question/answer pair.
- `plan`: plan permissions; asked for a short plan to create `hello.txt`, approved
  ExitPlanMode with unchanged input, then denied Write with “Fixture complete.
  Stop without writing files.” The CLI stopped without writing the file.
  Although launched with Haiku, assistant envelopes during planning identify
  Sonnet; after approval they identify Haiku again.

This plan recording differs from the earlier probe: the authoritative ExitPlanMode
tool call has `input.plan`, but its permission request has `input: {}`. The native
card recovers markdown from the matching tool-use ID and preserves `{}` for the
approval response. The CLI then emits `system/status` with `status: null` and
`permissionMode: default`. Its result text is “User has approved exiting plan mode.
You can now proceed.” and `tool_use_result` has `plan: null`, `isAgent: false`, and
`filePath`. Both interactive permission requests carry `requires_user_interaction`;
the subsequent Write request omits it.

`tools.jsonl` was recorded with Claude Code 2.1.310, Sonnet, bypass permissions,
and a fresh temporary folder. The launch specified low effort, then a successful
`apply_flag_settings` request set medium before the prompt. It contains only the
tool-use assistant envelopes and matching user results for Write, Edit, overwrite,
Read, Bash `ls`, and a failing Bash `ls missing-file`.

Structured results observed:
- Write: `type` (`create` or `update`), `filePath`, `content`, `structuredPatch`,
  `originalFile`, `userModified`.
- Edit: `filePath`, `oldString`, `newString`, `originalFile`, `structuredPatch`,
  `userModified`, `replaceAll`. Hunks have `oldStart`, `oldLines`, `newStart`,
  `newLines`, and prefix-marked `lines`.
- Read: `type: text` and `file` with `filePath`, `content`, `numLines`,
  `startLine`, `totalLines`. A trailing newline counts as an empty line here.
- Successful Bash: `stdout`, `stderr`, `interrupted`, `isImage`,
  `noOutputExpected`. Failed Bash: a string beginning with `Error: Exit code`.

This installation's init event does not advertise Grep or Glob, and ToolSearch
found neither. They could not be recorded; tests cover their plain-text fallback
without inventing a structured result shape. The effort request returned success
without a body. Init reported `per_turn_effort_active: true`; it did not expose
the selected level, nor did `result.modelUsage` or the initialize reply. The
initialize reply lists supported effort levels rather than the current value.

`background.jsonl` was recorded with Claude Code 2.1.310, Haiku, low effort,
bypass permissions, and a fresh temporary directory on October 25, 2026.
The first prompt was: "Use the Bash tool with run_in_background set to true to
run `sleep 8 && echo bgdone`. Then reply with just: started". After its result,
the second prompt was: "Use the Monitor tool to watch
`for i in 1 2; do sleep 3; echo tick$i; done` with timeout_ms 20000. Then reply
with just: watching". Stdin stayed open for 35 seconds after the second prompt.
Paths are normalized to `/tmp/mist-fixture`; installation metadata, thinking
signatures, token accounting, session/transport UUIDs, and thinking-token status
events are omitted. Streaming events and their original order are preserved.

Background protocol observations:
- `background_tasks_changed` precedes `task_started`, so initially unknown task
  kinds can be resolved once `tool_use_id` arrives. Both tasks use `local_bash`.
- `task_started` includes `task_id`, `run_id`, `tool_use_id`, `description`,
  `is_backgrounded: true`, and `task_type`.
- Bash's initial structured result has `backgroundTaskId` alongside empty
  `stdout` and `stderr`. Monitor's has `taskId`, `timeoutMs`, and `persistent`.
  Their text starts with `Command running in background with ID:` and
  `Monitor started (task`, respectively. Monitor was loaded through ToolSearch.
- `task_updated` includes a completed status and `end_time` inside `patch`.
  `task_notification` includes `run_id` as well as the documented task/tool IDs,
  status, output file, and summary. Monitor's summary says its stream ended.
- The authoritative running set reaches two tasks, then one, then `[]`.
- There are three automatic turns with fresh `system/init` and stream events;
  results have `origin.kind: task-notification`, `producer: session-task`, and
  an optional `runId`. One Monitor event starts a turn before either task ends.
