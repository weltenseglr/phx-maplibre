defmodule PhxMaplibre.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/weltenseglr/phx-maplibre"

  def project do
    [
      app: :phx_maplibre,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PhxMaplibre",
      description: description(),
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix, ">= 1.7.0 and < 2.0.0", runtime: false},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp description do
    "PubSub-first MapLibre GL JS integration for Phoenix LiveView: map events " <>
      "broadcast on demand to per-map topics, and any process can drive a map " <>
      "by broadcasting commands."
  end

  defp package do
    [
      files:
        ~w(lib priv examples package.json mix.exs .formatter.exs README.md CHANGELOG.md LICENSE),
      licenses: ["EUPL-1.2"],
      links: %{"GitHub" => @source_url},
      maintainers: ["weltenseglr"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "examples/ash_postgis_editor.md"
      ]
    ]
  end
end
