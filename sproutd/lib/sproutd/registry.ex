defmodule Sproutd.Registry do
  @moduledoc false

  @doc false
  def child_spec(opts) do
    opts
    |> Keyword.put(:name, __MODULE__)
    |> Keyword.put_new(:keys, :unique)
    |> Registry.child_spec()
  end
end