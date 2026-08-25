# Hancho

Hancho is an Elixir escript that manages a software factory for one Git repository.
See [ARCHITECTURE.md](ARCHITECTURE.md) for the current component boundaries,
recovery rules, invariants, and simplification direction.

Build and run it:

```sh
mix escript.build
./hancho --help
```

Print the installed version with `./hancho --version`.

Run all unit, integration, compile, formatting, and escript checks with:

```sh
mix check
```

This command runs normal and cross-process tests. It then builds and smoke-tests
a production escript and confirms that the test Harness adapter is not in the
archive.

The integration suite uses a Hancho-local `Jido.Harness` adapter. The adapter
does not call a live coding provider. It produces fixed events and makes a
fixed file change. This keeps the full workflow, run manager, event journal,
Git, worktree, and Bedrock test deterministic. Tests that call a live provider
must be separate and explicit because they need credentials and can have a
cost.

Initialize Hancho in a Git repository:

```sh
./hancho init
```

This creates `.hancho/config.toml`, `.hancho/forensics/`, `.hancho/logs/`,
`.hancho/prompts/`, `.hancho/workflows/`, and `.hancho/worktrees/`. Runtime files
also include the factory lease at `.hancho/factory.lock` and Harness operation
journals in `.hancho/harness/`. It installs the first workflow at
`.hancho/workflows/implement.yaml` and its editable agent prompt at
`.hancho/prompts/implement.md`. The complete `.hancho/` folder stays local and
ignored by Git. Initialization does not replace an existing workflow or prompt.

The distributed sources are `priv/workflows/implement.yaml` and
`priv/prompts/implement.md`. Hancho embeds both files when it builds the escript
and copies them into the repository during initialization.

The initial configuration is:

```toml
version = 1

[repo]
path = "/path/to/repository"

[logs]
enabled = true
path = "factory.jsonl"
format = "jsonl"
console = true
include_internal = false
sync_interval_ms = 1000
max_bytes = 10485760
max_files = 5
compress = true
```

Use `Hancho.Config.load/1` to read and validate the file. Use dot-delimited keys
such as `Hancho.Config.get(config, "repo.path")` to read values. The configured
repository path must resolve to the repository that Hancho discovered. If the
file does not exist, `load/1` returns a validated default configuration for the
repository without writing a file.

## Implementation workflow

Run the first factory workflow for one ready Beadwork task:

```sh
./hancho run implement hancho-123 --verbose
```

This command stays in the foreground. `--verbose` also streams safe summaries
of normalized provider events while the coding agent works. The workflow does
these steps in order:

1. Check the Git repository and Beadwork task. For a mapped task, load and
   validate the authoritative GitHub demand.
2. Claim the task.
3. Create a detached worktree in `.hancho/worktrees/`.
4. Render and save the agent prompt.
5. Call the configured CLI coding agent through Jido.Harness.
6. Check changed paths against the authoritative demand `Allowed Scope`, when
   configured.
7. Run `mix test`.
8. Create a conventional Git commit.
9. Fast-forward the original branch to the commit.
10. Remove the worktree.
11. Close and sync the Beadwork task.

The YAML file names each step, selects one approved `Jido.Action` module, and
sets its parameters. References are explicit:

- `$input.key` reads command input.
- `$run.id` reads the durable run ID.
- `$steps.step_name.key` reads an earlier step result.

Workflow structure does not use `config.toml`. Edit the repository-local YAML
file to change action parameters. Hancho permits only action modules in
`Hancho.Workflow.Registry`; it does not create atoms from YAML module names.

### Roles

A workflow is the complete factory pack. Its optional `roles` map gives stable
agent settings to one or more steps. A role can set its prompt with an inline
block or with a file relative to `.hancho/prompts/`. It can also select the
Harness provider, CLI executable, model, reasoning effort, and provider-supported
extra arguments:

```yaml
roles:
  implementer:
    provider: codex
    cli: /opt/codex/bin/codex
    model: gpt-5.6-codex
    reasoning_effort: high
    prompt_file: roles/implementer.md
  reviewer:
    provider: grok
    prompt: |
      Review the change against the accepted behavior and repository rules.

steps:
  - name: implement
    role: implementer
    action: Hancho.Actions.Implement
    params:
      prompt: "$steps.render_prompt.rendered"
      worktree_path: "$steps.create_worktree.worktree_path"
      timeout_ms: 1800000
```

Role values are defaults. An implementation step can override them. The role
prompt is added before the task prompt. Hancho resolves a role prompt file when
it loads the workflow and embeds the file content in the durable workflow
snapshot. A retry therefore does not read a changed prompt file. The selected
provider must support the requested model, reasoning effort, and extra
arguments. `xhigh` is supported for Codex and Grok through the normalized
Harness reasoning option.

Set `model` to pin a provider model. Hancho sends that exact configured value
to Harness and records it in dry-run output, provider progress, and the durable
implementation result. When `model` is absent, Hancho reports `provider default;
not pinned`. It does not claim that the provider's changing default is pinned.
Jido.Harness does not report the effective model for all providers, so Hancho
can always prove the requested model but cannot always prove provider fallback
behavior.

Hancho requests the Harness `workspace_write` sandbox for implementation. It
also sends path deny rules for common credential stores to Grok, Claude, and
Z.AI. The rules cover GitHub CLI hosts files, SSH private keys, cloud credential
files, `.env` files, and similar stores. The pinned Jido.Harness adapters for
Codex, Gemini, Amp, Kimi, OpenCode, and Pi do not expose a reliable file-read
deny control. For those adapters, Hancho records `workspace_sandbox_only` as a
limitation. Harness sandbox modes are provider requests, not a universal
operating-system read sandbox. Do not make host credential stores available in
an implementation workspace.

When two adjacent steps have different roles, Hancho writes a durable handoff
record before the first step completes. The record names the run, roles, steps,
artifact, payload, and lifecycle times. Handoffs are Bedrock records. They are
not files or terminal messages.

### Typed artifacts

Workflows can declare named JSON artifacts. A producing step validates its full
result against the declared type before the workflow can continue. A consuming
step can use `$artifacts.NAME.FIELD` references:

```yaml
artifacts:
  specification:
    type: object
    required: [gherkin]
    properties:
      gherkin: string

steps:
  - name: specify
    role: specifier
    action: Example.Specify
    produces: specification
  - name: implement
    role: implementer
    action: Hancho.Actions.Implement
    consumes: [specification]
    params:
      prompt: "$artifacts.specification.gherkin"
```

Supported types are `any`, `object`, `array`, `string`, `integer`, `number`,
and `boolean`. Hancho rejects an undeclared artifact, a duplicate producer, or
a consumer that occurs before its producer.

### Human attention

Use `Hancho.Actions.RequestAttention` for an approval or question:

```yaml
- name: approve_specification
  role: specifier
  action: Hancho.Actions.RequestAttention
  params:
    kind: approval
    title: Approve the specification
    body: Review the specification artifact before implementation starts.
```

The action creates a durable attention record and stops the run with its
attention ID. Resolve it, and then retry the same run:

```sh
./hancho attention list
./hancho attention approve RUN_ID:attention:approve_specification --response "Approved"
./hancho attention answer ID --response "Use the existing adapter"
./hancho retry RUN_ID
```

Attention kinds are `approval`, `clarification`, `scope_exception`, and
`recovery`. Decisions and answers remain in Bedrock with the run and step IDs.

### Cockpit

Start the loopback-only cockpit on an automatically selected port:

```sh
./hancho cockpit
```

Use `--port N` to select a port. The cockpit shows runs, queues, role handoffs,
and human attention. It refreshes every two seconds. An operator can approve,
reject, or answer a pending attention record. Hancho binds the server only to
`127.0.0.1`; it does not expose the cockpit on the network.

Every implementation workflow must declare one workspace before its
`Hancho.Actions.Implement` step. The default workflow uses
`Hancho.Actions.CreateWorktree`. An in-place workflow must use
`Hancho.Actions.UseRepository` and pass its `workspace_path` to implementation,
scope validation, verification, and commit actions:

```yaml
- name: use_repository
  action: Hancho.Actions.UseRepository
  params:
    repo_path: "$steps.preflight.repo_path"
    baseline: "$steps.preflight.baseline"
- name: implement
  action: Hancho.Actions.Implement
  params:
    worktree_path: "$steps.use_repository.workspace_path"
```

Hancho rejects an implementation workflow that does not declare exactly one
workspace. If an in-place run stops before commit, Hancho keeps the main branch
and HEAD checks but accepts the agent's dirty files for retry. A successful run
must still leave a clean repository at its recorded commit.

Scope and verification gates can use a bounded coding-agent repair policy:

```yaml
- name: validate_scope
  action: Hancho.Actions.ValidateScope
  params:
    worktree_path: "$steps.use_repository.workspace_path"
    issue: "$steps.claim.issue"
  on_error:
    codes:
      - changes_outside_allowed_scope
    repair_with: grok
    max_attempts: 1
    retry_step: validate_scope
```

`Hancho.Actions.Verify` supports the `verification_failed` code. A policy can
permit one to three attempts. It can retry only its own gate. The coding agent
uses the selected workspace and receives the exact gate error and parameters.
The repair prompt prohibits task, scope, branch, HEAD, and commit changes. Git
state, provider, storage, and unknown failures remain terminal.

Hancho writes each repair intent before it calls the agent. It then records the
provider result or error and runs only the failed gate again. Repair records
remain in the durable step state and in a stopped run's forensic report. A
recovered CLI process resumes an incomplete Harness repair operation. `--verbose`
shows normalized repair provider events and the attempt state.

The `Hancho.Actions.RenderPrompt` action accepts exactly one prompt source. A
file source is relative to `.hancho/prompts/`:

```yaml
params:
  repo_path: "$steps.preflight.repo_path"
  prompt_file: implement.md
  context:
    issue: "$steps.claim.issue"
```

Small prompts can be inline YAML block strings:

```yaml
params:
  repo_path: "$steps.preflight.repo_path"
  prompt: |
    Implement {{issue.id}}: {{issue.title}}

    {{issue.description}}
  context:
    issue: "$steps.claim.issue"
```

Prompt variables use `{{context.path}}` syntax. Hancho stops if a variable is
not present. The prompt-rendering step saves the exact template, rendered
prompt, source, and SHA-256 values before the CLI agent starts.

Hancho records every run and step in a local Bedrock cluster at
`.hancho/bedrock/`. A successful step saves its result in an atomic transaction
before the next step starts. If a step fails, Hancho stops the line, records the
failed step and error, and returns a nonzero exit status. It keeps a failed
implementation worktree for inspection when cleanup has not started. Bedrock
stores its cluster descriptor, coordinator, log, and storage-worker files in
this repository-local folder. Before a mutation command returns, Hancho waits
beyond Bedrock's five-second in-memory storage window and verifies a durability
marker. Run, step, and queue records have explicit schema and transition
versions. Hancho upgrades older records when it reads them.

Hancho records an intent before each external effect and records a receipt
after the effect completes. Effects include task claims, worktree changes,
commits, landing, cleanup, task closure, and task synchronization. On recovery,
Hancho reconciles an incomplete intent with Git, Beadwork, or the filesystem
before it continues.

Each run record also saves the exact loaded workflow YAML, its source path, and
its SHA-256 value. The activity log writes `workflow.snapshot` and
`prompt.snapshot` events with the exact workflow, prompt template, rendered
prompt, and matching hashes. These local audit records are intentionally not
redacted and can contain private task data.

## GitHub demands and Beadwork execution

GitHub owns promised scope and acceptance. Beadwork owns execution state and
dependencies. Hancho uses an explicit one-to-one mapping:

- One root GitHub Issue maps to one Beadwork epic.
- One GitHub sub-issue maps to one Beadwork task under the mapped epic.
- A Markdown task-list item is not a sub-issue and cannot map to a task.

Each Beadwork record stores the canonical GitHub URL and node ID. Each GitHub
Issue comment stores the Beadwork ID. The repository identity and GitHub node
ID are stable mapping identity; an Issue number is display data only.

Show the combined outstanding demand view without changing either system:

```sh
./hancho demands list --source all
./hancho demands list --source github
./hancho demands list --source beadwork
./hancho demands audit
```

The audit reports missing, incomplete, duplicate, conflicting, nested, and
orphaned records. An open Beadwork item with no matching open GitHub demand is
shown as `unmapped`. A root GitHub Issue without sub-issues is visible but is
not executable.

Preview or apply missing mappings explicitly:

```sh
./hancho demands sync --dry-run
./hancho demands sync --apply
```

Dry-run, list, and audit are read-only. Apply creates missing Beadwork epics and
tasks and writes the two backlinks. It can repair a missing backlink, but it
stops on duplicates, conflicting identities, wrong record types, wrong parent
links, or nested sub-issues. It does not close records in either system.
Apply holds the repository factory lease, records its intent and receipt in
`.hancho/logs/demand-sync.jsonl`, and refreshes the non-authoritative cache at
`.hancho/demand-mappings.json`. A failed or interrupted apply can be run again;
the canonical markers make creation and backlink repair idempotent.

The first version reads at most 100 open GitHub Issues and 100 comments on each
Issue and supports one sub-issue level. It stops instead of returning an
incomplete view when either limit is exceeded. The commands require authenticated
`gh` and initialized `bw` clients for the current repository.

Before a mapped workflow can claim work or call a coding provider, Hancho loads
the selected GitHub sub-issue by node ID. It proves the repository, URL, node
ID, GitHub backlink, and mapped parent. A missing, closed, or mismatched demand
stops the workflow. Hancho stores the repository identity, URL, node ID, title,
full body, update time, and a content SHA-256 in the durable preflight result.
The prompt and scope gate use this same snapshot. Resume reuses it and does not
replace it with the copied Beadwork description. GitHub remains the source of
truth; `.hancho/demand-mappings.json` is never a demand-body fallback.

## Foreground queues

Run an explicit number of ready Beadwork tasks through one workflow:

```sh
./hancho queue implement --source beadwork-ready --count 5 --verbose
```

Preview the exact task selection and run read-only repository reconciliation
without writing state, claiming work, creating a worktree, or calling an agent:

```sh
./hancho queue implement --source beadwork-ready --count 1 --dry-run
```

The preview reports the branch, commit, clean status, retained worktree count,
provider, configured model or unpinned state, and implementation and
verification timeouts. It also compiles the
workflow and checks action modules, parameters, references, prompt files,
provider readiness, and required executables. A repository, worktree, or
workflow error stops the preview before a live run can start.

If `bw ready` returns fewer tasks than the requested count, Hancho derives ready
tasks from `bw list --all`. A task is ready when it is open or in progress and
each named blocker is closed or is an earlier task in the same serial queue.
Execution cards with a `Queue ordinal` in their description are selected in
that order. A task with another unresolved blocker is not selected.

Hancho first reads `bw ready --json` and `bw list --all --json`. It keeps ready
items with the `task` type only when the task has canonical GitHub URL and node
markers and its parent is a mapped Beadwork epic.
It uses the full-list fallback described above only when that command returns
too few tasks. Hancho requires the requested number before it starts. It saves
their order in Bedrock and runs one child workflow at a time. Each child has a
deterministic run ID such as `queue-123-001` and keeps its normal workflow,
prompt, step, and log snapshots.

The command stays in the foreground and stops on the first failed child. It
does not retry, skip, repair, or continue. `--verbose` prints queue selection,
the checks before and after each child, child run IDs, landed commits, and the
terminal queue result. During implementation it also prints normalized provider
text, thought, tool, file, plan, usage, approval, and terminal updates. Tool
results are summarized; Hancho does not print their full payloads to the
console. Normal mode keeps the short periodic implementation progress lines.
The terminal summary reports durable queue elapsed time, each task's elapsed
time, configured model, and provider usage. Hancho adds only usage that the
adapter identifies as run-scoped. It labels Grok values as provider-cumulative
and does not add them. Missing and unknown-scope values remain explicit.
Hancho also saves queue events in the factory log:

- `queue.started`
- `queue.reconciled`
- `queue.item_started`
- `queue.item_completed`
- `queue.stopped`
- `queue.reconciliation_failed`
- `queue.completed`

At queue creation and each child boundary, Hancho compares durable queue state
with the local repository. The main branch, HEAD, and clean status must match.
The `.hancho/worktrees/` directories and Git worktree registrations must also
match the child workflow state. A mismatch stops the queue with a
`filesystem_out_of_sync` error. Hancho does not delete worktrees, prune Git
state, reset HEAD, or change branches to repair a mismatch.

One Hancho factory can own a repository at a time. The factory lease has a
heartbeat. A new process can reclaim a stale lease after the recorded owner
process ends.

## Retry and resume

Continue one stopped workflow from its stopped step:

```sh
./hancho retry RUN_ID --verbose
```

Hancho keeps completed step outputs and does not run completed steps again. It
can also recover a run that ended while a step was running. It checks the saved
main-branch commit, retained worktree, and pending external effects before it
changes durable state. A mismatch stops the retry.

Continue one stopped queue from its stopped child:

```sh
./hancho resume QUEUE_ID --verbose
```

Hancho retries the stopped child with its original run ID. If the queue stopped
before that child created a run, Hancho starts the child with the saved run ID.
After that child completes, Hancho runs the pending children in their saved
order. Completed children do not run again. Queue activity includes
`queue.resumed`, `queue.item_retried`, and `queue.item_restarted` events.
Workflow activity includes a `workflow.retry_started` event.

## Run inspection

Read one durable run without starting or changing it:

```sh
./hancho run inspect RUN_ID
```

The report shows the workflow status, start and finish times, step durations,
provider and Harness run IDs, verification summary, landed or created commit,
retained worktree, failure data, and the forensic report path when one exists.
It also shows the configured model and normalized provider usage when available.

When a workflow stops, Hancho writes a private JSON report to
`.hancho/forensics/runs/RUN_ID.json`. When a queue stops, Hancho writes a second
report to `.hancho/forensics/queues/QUEUE_ID.json`. These reports include the
primary error, a separate reconciliation error when applicable, Git status,
workflow artifacts, cleanup results, and links between the queue and child run.
Report files use mode `0600`, and their directories use mode `0700`. Reports can
contain source paths and agent output. Keep the complete `.hancho/` directory
private.

During implementation, Hancho records an `implement.progress` event every 30
seconds by default. It records the Harness run ID, elapsed time, observed event
count, and latest normalized event type. It does not copy raw provider output
into the progress event. Set `progress_interval_ms` on the implementation step
to change the interval. Repair calls use `repair.progress` events and the
interval in the gate's `on_error` policy.

Hancho also records a warning-level `implement.andon` event when the provider
has produced no new event for two minutes. New provider activity resets the
warning, so Hancho emits only one warning for each quiet period. The warning
does not stop the run. Set `andon_warning_ms` on the implementation step to
change the threshold. Repair calls use `repair.andon` and the threshold in the
gate's `on_error` policy. The separate `idle_timeout_ms` remains the stop limit.

Hancho keeps a second warning-only clock for productive progress. Provider
thought and text events count as activity, but they do not reset this clock.
A normalized file change or a completed test/build result resets it. After
`productive_warning_ms` (two minutes by default), Hancho writes
`implement.productivity_andon` or `repair.productivity_andon`. The warning does
not cancel the provider. This makes long active runs with no bounded result
visible without adding an unsafe automatic retry.

Verification writes complete merged standard output to a protected file in
`.hancho/logs/`. Factory activity contains one `verify.progress` event per 64
KiB and one `verify.completed` summary. It does not write one factory event for
each test-runner output chunk. `hancho run inspect` reports the complete output
path.

Command results keep a bounded output tail in memory. They report total output
bytes and whether the in-memory result was truncated. The full verification
log remains available at the protected output path.

## Retained worktrees

Hancho keeps each task isolated. The coding provider and verification command
use `deps` and `_build` in that task's worktree. Hancho creates these directories
and proves that they are writable before it starts the process. It rejects a
symbolic link at either path. A setup failure stops the action before provider
execution. Hancho does not share or copy Mix build data between worktrees.

List retained worktrees and their total storage use:

```sh
./hancho worktrees list
```

Inspect Git registration, commit, changed paths, and generated storage for one
run:

```sh
./hancho worktrees inspect RUN_ID
```

Remove `_build`, `deps`, and `cover` from one registered retained worktree:

```sh
./hancho worktrees clean RUN_ID
```

The clean command keeps the worktree, Git registration, source changes, and
all other diagnostic files.

Hancho also runs this safe cleanup after a stopped worktree workflow. It removes
only untracked `_build`, `deps`, and `cover` directories. It does not remove a
directory when Git tracks a file below it. The cleanup result and reclaimed byte
count are in the run forensic report. An in-place workflow keeps these generated
directories because they belong to the main repository workspace.

## Factory activity logs

Hancho writes factory activity to `.hancho/logs/factory.jsonl` by default. These events contain command output, workflow changes, agent activity, and other factory work. They are separate from the normal diagnostic logs for the Hancho application.

The default JSON Lines format writes one event on each line. Each event has a
schema version, sequence number, UTC timestamp, level, event name, message,
message encoding, and metadata. A sequence sidecar keeps sequence numbers
monotonic across writer restarts. The text format also writes one escaped event
on each line. Audit write failures are reported, but they do not replace the
factory operation result.

The log options have these effects:

- `enabled` starts or stops activity logging.
- `path` sets a safe path inside `.hancho/logs/`.
- `format` is `jsonl` or `text`.
- `console` sends captured events to the console as well as the file.
- `include_internal` also captures Hancho Logger events that use the `[:hancho]` domain.
- `sync_interval_ms` sets the file-sync interval. A value of `0` syncs after each event.
- `max_bytes` rotates the current file at the given size.
- `max_files` sets how many old files remain.
- `compress` compresses rotated files with gzip.

Use `Hancho.Log` to own one activity log for a factory run:

```elixir
{:ok, project} = Hancho.Project.discover()
{:ok, config} = Hancho.Config.load(project)
{:ok, log} = Hancho.Log.open(project, config, metadata: %{run_id: "build-42"})

:ok = Hancho.Log.write(log, "step started", event: "workflow.step_started")

sink = Hancho.Log.output_sink(log, metadata: %{command: "mix test"})
{:ok, result} = Hancho.Command.run("mix", ["test"], cwd: project.root, on_output: sink)

:ok = Hancho.Log.close(log)
```

The writer serializes events. It uses Elixir Logger metadata and the OTP file handler for filtering, file sync, rotation, compression, and console routing. `Hancho.Command` stops its process group if the activity sink cannot write an output event.

Inspect the current repository and required local tools:

```sh
./hancho doctor
```

Hancho uses [Beadwork](https://github.com/jallum/beadwork) for durable work tracking. This repository uses the `hancho` Beadwork issue prefix.

Hancho uses [Jido.Harness](https://github.com/agentjido/jido_harness) as its normalized runtime for CLI coding agents.

Hancho uses [Jido.Action](https://hex.pm/packages/jido_action) for validated
workflow actions and [yaml_elixir](https://hex.pm/packages/yaml_elixir) for
workflow definitions. Hancho uses [Bedrock](https://github.com/bedrock-kv/bedrock)
for durable, repository-local workflow state. The dependency points directly to
the tested `hancho/bedrock-next` integration commit in Mike Hostetler's Bedrock
fork. That commit combines the current upstream recovery stack with the
layout-index fixes required by Hancho.

Hancho uses the [`git`](https://hex.pm/packages/git) package behind `Hancho.Git`.
Git processes run through erlexec so Hancho can stop a timed-out command and its
child processes. Hancho creates factory commits without GPG signing so an
unattended run does not wait for an interactive key or a locked GPG database.
