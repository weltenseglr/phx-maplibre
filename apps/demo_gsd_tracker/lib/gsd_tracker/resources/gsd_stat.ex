defmodule GsdTracker.GSDStat do
  use Ash.Resource,
    domain: GsdTracker.Ash,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "gsd_stats"
    repo GsdTracker.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
    end

    attribute :gsd_id, :uuid do
      allow_nil? false
    end

    attribute :flock_id, :uuid do
      allow_nil? true
    end

    attribute :partner_id, :uuid do
      allow_nil? true
    end

    attribute :location, AshGeo.Geometry
    attribute :status, :atom
    attribute :movement_vector, :map
    attribute :speed_kmh, :decimal
  end

  relationships do
    belongs_to :gsd, GsdTracker.GSD do
      define_attribute? false
      source_attribute :gsd_id
      allow_nil? false
    end
  end

  identities do
    identity :unique_gsd_timestamp, [:gsd_id, :timestamp]
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :timestamp,
        :gsd_id,
        :flock_id,
        :partner_id,
        :location,
        :status,
        :movement_vector,
        :speed_kmh
      ],
      update: [
        :timestamp,
        :gsd_id,
        :flock_id,
        :partner_id,
        :location,
        :status,
        :movement_vector,
        :speed_kmh
      ]
    ]

    create :bulk_upsert do
      upsert? true
      upsert_identity :unique_gsd_timestamp
      upsert_fields [:flock_id, :partner_id, :location, :status, :movement_vector, :speed_kmh]

      accept [
        :timestamp,
        :gsd_id,
        :flock_id,
        :partner_id,
        :location,
        :status,
        :movement_vector,
        :speed_kmh
      ]
    end
  end
end
