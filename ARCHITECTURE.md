# Hancho architecture

Hancho is a single-repository, foreground workflow engine. It runs one factory
operation at a time. It saves enough state to inspect, retry, or resume work
after a process failure.

This document describes the current design and the safe direction for later
simplification.

## Control flow

```text
CLI
  -> factory lease
  -> workflow runner or queue runner
  -> sequential workflow runtime
  -> role defaults and typed artifact contract
  -> validated action
  -> Git, Beadwork, Harness, or filesystem effect

Every durable transition
  -> workflow store
  -> Bedrock transaction
  -> explicit durability flush at a command or queue boundary
```

The CLI parses input and acquires the filesystem factory lease. The lease stops
two local Hancho processes from changing one repository at the same time.

`Hancho.Workflow.Runner` starts or retries one workflow. It opens the audit log,
creates the durable run, and starts `Hancho.Workflow.Runtime`.

`Hancho.Workflow.Runtime` is a `:gen_statem` process. It runs one action at a
time. It does not schedule parallel steps. It saves each step transition before
it moves to the next step.

`Hancho.Workflow.QueueRunner` selects issues and runs child workflows in their
saved order. It owns queue recovery, repository checks at child boundaries,
progress reports, and queue forensics.

`Hancho.MatrixRun` is a separate, non-workflow comparison path. It takes the
factory lease, records one clean commit, creates one detached worktree for each
selected Harness cell, and runs cells in bounded concurrent batches. It keeps
cell evidence and writes JSON and Markdown reports. It does not use Bedrock,
change the source branch, rank results, or select a winner.

`Hancho.Workflow.Store` is the transaction boundary for run, step, effect,
repair, queue, role handoff, and human attention records. `Hancho.State.Bedrock` starts the local Bedrock
cluster and implements the durability barrier.

## State ownership

| State | Owner | Source of truth |
| --- | --- | --- |
| Current local process | Factory lease | `.hancho/factory.lock` |
| Active durable queue | Queue store | Bedrock active-queue key |
| Run and step lifecycle | Workflow runtime | Bedrock run and step records |
| External operation lifecycle | Effect module | Bedrock intent and receipt records |
| Role-to-role work | Workflow runtime | Bedrock handoff records |
| Human decisions and answers | Attention action and cockpit | Bedrock attention records |
| Git and worktree state | Git and filesystem | Reconciled with saved expectations |
| Matrix worktrees and reports | Matrix runner | `.hancho/matrix-runs/` |
| Promised scope and acceptance | GitHub Issues | Read through the GitHub adapter |
| Execution tasks and dependencies | Beadwork | Read and changed through the Beadwork adapter |
| Cross-system identity | Bidirectional markers | Audited by `Hancho.Demands` |
| Human-readable history | Audit and reporter modules | JSONL log and forensic reports |

The factory lease and active-queue key have different purposes. The lease stops
concurrent local writes. The active-queue key survives a process failure and
identifies work that must resume. Keep both controls.

## Recovery rules

Hancho records an intent before an external effect. It records a receipt after
the effect completes. If a process stops between these writes, recovery checks
the external system before it repeats or accepts the effect.

Run recovery compares the saved repository state with the current Git and
worktree state. Queue recovery also checks the saved child position and child
run. Hancho stops when it cannot prove that the states agree. It does not make a
destructive repair automatically.

Queue item `status` is the only queue-item lifecycle field. The child run record
shows whether a running item started its child workflow. This avoids a second
`phase` field that can conflict with `status`.

## Important invariants

- One workflow step runs at a time.
- One queue child runs at a time.
- Each matrix cell starts from the same recorded commit in a different detached
  worktree.
- Matrix usage totals contain only provider-reported, run-scoped additive
  values.
- A matrix comparison does not select a winner when evidence is incomplete.
- Role handoffs do not enable parallel execution.
- A typed artifact is valid before it becomes available to a later step.
- Role prompt files are embedded in the durable workflow snapshot.
- Serial worktrees can share only repository-local, content-keyed Mix caches.
- A successful transition is durable before the next external effect starts.
- A read-only inspection does not write a durability marker.
- Factory-created commits do not use interactive GPG signing.
- Recovery does not delete a worktree, reset Git, or clear an active queue
  without proof that the action is safe.
- Demand list and audit operations do not change GitHub, Beadwork, Git, or
  Hancho durable state.
- A queue can select only a mapped Beadwork task under a mapped epic.
- Demand synchronization creates or repairs links but never copies closure
  state between GitHub and Beadwork.
- Bedrock remains pinned to the tested Mike Hostetler fork until upstream has
  the required layout and recovery fixes.

## Simplification direction

The next changes should keep the invariants and reduce the size of the
orchestration modules.

1. Split `Workflow.Store` into small run, queue, and effect repositories behind
   one Bedrock transaction adapter. Keep one record codec and one upgrade path.
2. Extract one repository snapshot and comparison module. Run and queue
   reconciliation now contain similar branch, HEAD, path, and worktree checks.
3. Split `QueueRunner` into a coordinator, queue transition service, and child
   workflow service. Use one context struct instead of high-arity private
   functions.
4. Add an active-queue status command and an explicit safe recovery command.
   An error must show the queue ID and the exact resume or inspect command.
5. Replace the fixed durability wait when the Bedrock API can acknowledge a
   durable version directly. Until then, flush only at real mutation boundaries.

Do not combine the factory lease with the active-queue key. Do not remove effect
intent and receipt records. These parts add code, but they protect unattended
execution from duplicate external work and unsafe recovery.
