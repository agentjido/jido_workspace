# 00.01 Work on one tree

Open the memory profile and write a report through Workspace. Run `cp` with
an argument list and the relative working directory `reports`. Read the
copy through Workspace. The command and the file calls use the same tree.

The test checks the copied bytes and verifies that a read returns `:closed`
after the handle closes. [Example](example.ex) · [Test](example_test.exs)

```sh
mix test examples/00_core/00_01_work_on_one_tree/example_test.exs --include integration
```

The Docker lesson calls this same report function. [Repeat the workflow on Docker](../00_02_repeat_on_an_isolated_provider/README.md)
