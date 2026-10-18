defmodule Jido.Workspace.Deploy.Recipe do
  @moduledoc """
  Ordered source deployment steps. Commands use executable/argument tuples.
  Preparation precedes activation. A failed verification requires explicit recovery.
  """
  defstruct prepare: [], service: nil, verify: nil

  def valid?(nil), do: true

  def valid?(%__MODULE__{} = recipe) do
    is_list(recipe.prepare) and Enum.all?(recipe.prepare, &command?/1) and
      (is_nil(recipe.verify) or command?(recipe.verify)) and
      (is_nil(recipe.service) or
         match?(
           %{executable: exe, args: args} when is_binary(exe) and is_list(args),
           recipe.service
         ))
  end

  def valid?(_), do: false

  defp command?({exe, args}),
    do: is_binary(exe) and is_list(args) and Enum.all?(args, &is_binary/1)

  defp command?({exe, args, opts}), do: command?({exe, args}) and Keyword.keyword?(opts)
  defp command?(_), do: false
end
