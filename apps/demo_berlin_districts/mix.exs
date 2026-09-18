defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_berlin_districts,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Demo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phx_maplibre, in_umbrella: true},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2.8"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:jason, "~> 1.2"},
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.12.4"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": [
        "cmd --cd assets npm install",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        &copy_maplibre_worker/1
      ],
      "assets.build": [
        &copy_maplibre_worker/1,
        "tailwind demo_berlin_districts",
        "esbuild demo_berlin_districts"
      ],
      "assets.deploy": [
        &copy_maplibre_worker/1,
        "tailwind demo_berlin_districts --minify",
        "esbuild demo_berlin_districts --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end

  defp copy_maplibre_worker(_args) do
    dist = "assets/node_modules/maplibre-gl/dist"

    # MapLibre 5 embeds its worker; 6 ships a module and its shared dependency.
    if File.exists?(Path.join(dist, "maplibre-gl-worker.mjs")) do
      File.mkdir_p!("priv/static/assets/js")

      for file <- ["maplibre-gl-worker.mjs", "maplibre-gl-shared.mjs"] do
        File.cp!(Path.join(dist, file), Path.join("priv/static/assets/js", file))
      end
    end
  end
end
