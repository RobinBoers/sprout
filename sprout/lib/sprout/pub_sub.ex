defmodule Sprout.PubSub do
  @moduledoc false

  defp topic(cid), do: "sprout:#{cid}"

  @spec subscribe(Sprout.cid()) :: :ok | {:error, term()}
  def subscribe(cid \\ ProcessTree.get(:cid)) do
    Phoenix.PubSub.subscribe(__MODULE__, topic(cid))
  end

  @spec broadcast(term(), Sprout.cid()) :: :ok | {:error, term()}
  def broadcast(message, cid \\ ProcessTree.get(:cid)) do
    Phoenix.PubSub.broadcast(__MODULE__, topic(cid), message)
  end

  @spec unsubscribe(Sprout.cid()) :: :ok
  def unsubscribe(cid \\ ProcessTree.get(:cid)) do
    Phoenix.PubSub.unsubscribe(__MODULE__, topic(cid))
  end

  @doc false
  def child_spec(opts) do
    opts
    |> Keyword.put(:name, __MODULE__)
    |> Phoenix.PubSub.child_spec()
  end
end