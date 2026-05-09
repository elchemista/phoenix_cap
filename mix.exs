defmodule PhoenixCap.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_cap,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "A tiny Phoenix-native verifier for the Cap proof-of-work widget.",
      start_permanent: Mix.env() == :prod,
      package: package(),
      dialyzer: dialyzer(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {PhoenixCap.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      files: [
        "assets",
        "lib",
        "mix.exs",
        "README.md"
      ],
      licenses: ["MIT", "Apache-2.0"],
      links: %{}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end
end
