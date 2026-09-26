defmodule Sproutd.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Sproutd.Registry,
      Sproutd.Pool
    ]

    Supervisor.start_link(children, [
      strategy: :one_for_one,
      name: Sproutd.Supervisor
    ])
  end
end