defmodule GsdTracker.LandCover do
  use Ash.Resource,
    domain: GsdTracker.Ash,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "land_covers"
    repo GsdTracker.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :landuse_type, :atom do
      allow_nil? false
      constraints one_of: [:residential, :commercial, :industrial, :retail, :water]
    end

    attribute :geometry, AshGeo.Geometry

    attribute :source, :string do
      default "osm"
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:landuse_type, :geometry, :source],
      update: [:landuse_type, :geometry, :source]
    ]

    read :water_polygons do
      filter expr(landuse_type == :water)
    end

    read :land_polygons do
      filter expr(landuse_type != :water)
    end
  end
end
