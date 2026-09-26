defmodule Sprout.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprout,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Sprout.Application, []},
      extra_applications: [:logger, :erlexec]
    ]
  end

  defp deps do
    [
      {:erlexec, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:see, "~> 0.0.1-rc1"},
      {:parent, "~> 0.13.0"},
      {:typed_struct, "~> 0.3.0"},
      {:process_tree, "~> 0.3.0"}
    ]
  end
end
