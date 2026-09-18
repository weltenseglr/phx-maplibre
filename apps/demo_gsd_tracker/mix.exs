defmodule GsdTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo_gsd_tracker,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GsdTracker.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2.8"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:ash, "~> 3.4"},
      {:ash_postgres, "~> 2.0"},
      {:ash_geo, "~> 0.3"},
      {:geo, "~> 3.6"},
      {:geo_postgis, "~> 3.7"},
      {:jason, "~> 1.4"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:req, "~> 0.7"},
      {:postgrex, ">= 0.0.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phx_maplibre, in_umbrella: true}
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
        "tailwind demo_gsd_tracker",
        "esbuild demo_gsd_tracker"
      ],
      "assets.deploy": [
        &copy_maplibre_worker/1,
        "tailwind demo_gsd_tracker --minify",
        "esbuild demo_gsd_tracker --minify",
        "phx.digest"
      ]
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
