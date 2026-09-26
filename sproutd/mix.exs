defmodule Sproutd.MixProject do
  use Mix.Project

  def project do
    [
      app: :sproutd,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Sproutd.Application, []}
    ]
  end

  defp deps do
    [
      {:sprout, path: "../sprout"},
      {:req_llm, "~> 1.10"}
    ]
  end
end
