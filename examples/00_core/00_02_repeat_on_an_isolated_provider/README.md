# 00.02 Repeat the workflow on Docker

Open the memory profile, run the report workflow, and close the workspace.
Repeat with the Docker profile. The same report function writes the input,
passes filenames with spaces as literal arguments to `cp`, and reads back
the copied bytes. Only the profile name changes.
[Report workflow](../00_01_work_on_one_tree/example.ex) · [Profile runner](example.ex) · [Test and profile configuration](example_test.exs)

Use a local Docker engine with an installed Alpine image. Set
`JIDO_SANDBOX_IMAGE` to the installed tag. The profile requires container
isolation and disabled networking.

```sh
JIDO_SANDBOX_DOCKER=1 JIDO_SANDBOX_IMAGE=alpine:3.20 mix test examples/00_core/00_02_repeat_on_an_isolated_provider/example_test.exs --include integration
```
