defmodule Vigil.MixProject do
  use Mix.Project

  def project do
    [
      app: :vigil,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :eex, :inets, :ssl],
      mod: {Vigil.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:tz, "~> 0.28"},
      {:plug, "~> 1.16"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      vigil: [
        include_executables_for: [:unix]
      ]
    ]
  end
end
