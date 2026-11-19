# 00 Core Workspace API

Use a report to follow the file, command, policy, and restore operations.
Memory and Docker use `Jido.Workspace`. The host selects a named profile
when it opens a workspace.

1. [Work on one tree](00_01_work_on_one_tree/README.md)
2. [Repeat the workflow on Docker](00_02_repeat_on_an_isolated_provider/README.md)
3. [Enforce a restricted profile](00_03_enforce_a_restricted_profile/README.md)
4. [Restore in a fresh BEAM](00_04_restore_in_a_fresh_beam/README.md)

The report workflow uses paths relative to the workspace root and passes
command arguments as a list. The Docker profile requires container isolation
and disabled networking. Both providers can reopen a saved tree when the
profiles use the same configured snapshot store.

Follow the two-session walkthrough to save a JSON reference and reopen the
report after a BEAM restart. [Save and reopen a snapshot](../README.md#save-and-reopen-after-a-beam-restart)
