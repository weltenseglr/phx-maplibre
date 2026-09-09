defmodule PhxMaplibreHexConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :phx_maplibre_hex_consumer, version: "0.0.0", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:phx_maplibre, path: "deps/phx_maplibre"}
    ]
  end
end
