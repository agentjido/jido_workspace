# 00.03 Enforce a restricted profile

Prepare a report in a writable memory workspace and save the tree. Open
that snapshot with a read-only profile. Use the same calls on memory and
Docker. The profile permits reads and refuses writes and commands, including
`cat`. The test reads the report again to confirm its contents.
[Example](example.ex) · [Tests](example_test.exs)

The tests also refuse a profile with an invalid policy, a profile name that
does not exist, and a memory profile that requires container isolation.
A Docker command can read the report in the workspace but cannot read the
test file on the host outside the workspace.

```sh
mix test examples/00_core/00_03_enforce_a_restricted_profile/example_test.exs --include integration
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/00_core/00_03_enforce_a_restricted_profile/example_test.exs --include integration
```
