defmodule Jido.Workspace.DurableReferencesTest do
  use ExUnit.Case, async: true

  alias Jido.Workspace.{CommandRef, InfrastructureRef, Snapshot}

  test "durable maps round-trip through JSON using the same schema interface" do
    assert {:ok, snapshot} = Snapshot.new("results", String.duplicate("a", 64))
    assert {:ok, infra} = InfrastructureRef.new("provider-a", "resource/42")
    assert {:ok, command} = CommandRef.new(infra, "command/26")

    for {surface, value} <- [
          {Snapshot, snapshot},
          {InfrastructureRef, infra},
          {CommandRef, command}
        ] do
      assert {:ok, ^value} = surface.parse(Jason.decode!(Jason.encode!(value)))
      assert {:ok, ^value} = Zoi.parse(surface.schema(), value)
      assert {:error, _} = surface.parse(Map.put(value, :format, 2))
      assert {:error, _} = surface.parse(Map.put(value, :pid, self()))
    end

    assert {:error, _} = Snapshot.parse(infra)
    assert {:error, _} = InfrastructureRef.parse(snapshot)
    assert {:error, _} = CommandRef.new(snapshot, "command/26")
    assert {:error, _} = Snapshot.new("results", "../invalid")
  end
end
