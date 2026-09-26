defmodule Sprout.Application do
  @moduledoc false
  use Application

  defp generate_cid do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  @impl true
  def start(_type, _args) do
    Process.put(:cid, generate_cid())

    children = [Sprout.PubSub] ++
      if interactive?() do
        [
          Sprout.Client,
          Sprout.Socket,
          Sprout.PTY,
          Sprout.TTY,
          Sprout.Bridge
      ]
      else
        []
      end

    Supervisor.start_link(children, [
      strategy: :one_for_one,
      name: Sprout.Supervisor
    ])
  end

  defp interactive? do
    "SPROUT_INTERACTIVE"
    |> System.get_env("")
    |> String.downcase()
    |> then(&(&1 in ~w(true 1 on yes)))
  end
end