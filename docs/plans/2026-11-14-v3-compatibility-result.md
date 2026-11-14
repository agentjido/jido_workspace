# Workspace v3 compatibility result

Starting branch: `main`. Starting revision: `d52101451a9d74e61729d994978d9e8bc62758d3`.
The primary branch was retained to preserve local and concurrent work.
The delivery report names the exact published branch and commit.

Status: checked v3 source candidate; Hex publication remains blocked.

## Boundary and implementation

Workspace owns file/session lifetime and host-selected resource policy. Shell
owns execution; VFS owns adapters and immutable captures. Workspace uses core
only in its test graph. No core runtime dependency was added. The API guide
now states the tested ownership boundary.

The checkout already had manifest and lock edits from core `05723b96` to
`047bf746` before this task. They match the confirmed target required by this
assignment, and the executed boundary checks use them. These two scoped pin
edits were committed concurrently as `93ad3c84a3bec7bbfcc6807132c3aecc851eed5c` by the checkpoint work owner. This task builds on that unchanged commit; it does not claim authorship of the pin repair. Other local plan files stay separate.

## Checks

- `mix test`: 52 passed, 66 excluded by standard integration/provider tags.
- `mix quality`: passed, including Dialyzer and Doctor.
- `mix test test/examples/action_signal_boundary_test.exs test/examples/workspace_contract_test.exs test/examples/workspace_file_api_test.exs --include integration`: 27 passed.
- The v3 examples check core Joi input validation, Actions, committed/failed AgentServer TurnResults, Signals, workspace policy, shell reads, captures, revision checks, file replacement, and cleanup.
- Isolated Jidoka: 4 focused tests passed; see shared evidence.
- `mix hex.build`: blocked by the existing `override: true` on Zoi. The manifest also has intentional sibling path overrides, Git source fallbacks, and a test-only Git core pin. The Hex dependency declarations need a separate release preparation once the required package versions exist. No gate was bypassed.

The source candidate supports the pinned v3 graph. It is not a publishable Hex
candidate. Live Sprite, Docker, provider CLI, and unselected integration
examples were not run. The existing sibling path setup was preserved.

## Shared evidence and limits

Date: 2026-11-14. GitHub API checks confirmed consolidated core `release/v3`
at `047bf746330a2fbe7c3b25c045552e0303c97eaf`. Tests used Elixir 1.20.4,
OTP 29.1.2. Core owns Action, Signal, and AI modules. No separate legacy
core package is present in either new consumer fixture dependency tree.
No mandatory core runtime dependency was added to a standalone package.

The package sources and consumer fixtures were self-checked. A separate source
review checked the Harness reconciliation. No live model or paid provider
check ran. No live app home, checkpoint, or database was changed.

Jidoka started on `release/v3` at
`5b697d3d3a0f96bc7baf063687d4a98f31a0565a`, with local checkpoint work.
Its source was copied to `/private/tmp/five-v3/jidoka`. Only that copy's
manifest used paths to the four candidate libraries. Core remained pinned to
`047bf746`. The command below passed 4 tests with a temporary SQLite database:

```sh
MIX_TARGET=desktop ERL_FLAGS='+S 4:4' mix test test/jidoka/workspaces_test.exs test/jidoka/inference/detector_test.exs
```

The first two tests cover write/read/list/capture, mutation policy, storage
selection refusal, and close. The other two cover provider discovery and
failure normalization. They do not run a live Harness provider. The original
Jidoka checkout and its existing local changes were preserved.

## Release order

Publish the required consolidated core and shared dependencies first. ReqLLM
1.30.0 and Zoi 0.19.0 are already available. Release VFS before Shell, then
Workspace, then update and check Jidoka dependency pins. Character and Harness
can release independently after their shared dependencies are available.
Migrate Hancho before claiming it supports the new Harness candidate. No
registry publication, release, merge, or PR was part of this work.

## Static config audit

From the primary source directory, `mix credo --strict --config-file .credo.exs`
passed with 18 checks. This explicitly selects the repository config and
avoids temporary-directory config ancestry. The shared `/private/tmp/.credo.exs`
was not changed.
