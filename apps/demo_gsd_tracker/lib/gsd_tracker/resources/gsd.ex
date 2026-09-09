defmodule GsdTracker.GSD do
  use Ash.Resource,
    domain: GsdTracker.Ash,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "gsds"
    repo GsdTracker.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :commissioning_date, :utc_datetime do
      allow_nil? false
    end

    attribute :decommissioning_date, :utc_datetime do
      allow_nil? true
    end

    attribute :partner_id, :uuid do
      allow_nil? true
    end

    attribute :flock_id, :uuid do
      allow_nil? true
    end

    attribute :status, :atom do
      allow_nil? false

      constraints one_of: [
                    :maintenance,
                    :charging,
                    :surveillance,
                    :simulating,
                    :target_tracking,
                    :aerial_surveillance,
                    :moving_to_new_target
                  ]
    end

    attribute :current_location, AshGeo.Geometry do
      allow_nil? true
    end

    attribute :speed_kmh, :decimal do
      allow_nil? true
    end
  end

  relationships do
    belongs_to :flock, GsdTracker.Flock do
      define_attribute? false
      source_attribute :flock_id
      allow_nil? true
    end

    has_many :stats, GsdTracker.GSDStat
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [
        :commissioning_date,
        :decommissioning_date,
        :partner_id,
        :flock_id,
        :status,
        :current_location,
        :speed_kmh
      ],
      update: [
        :commissioning_date,
        :decommissioning_date,
        :partner_id,
        :flock_id,
        :status,
        :current_location,
        :speed_kmh
      ]
    ]

    read :by_id do
      argument :id, :uuid do
        allow_nil? false
      end

      filter expr(id == ^arg(:id))
      get? true
    end
  end
end
