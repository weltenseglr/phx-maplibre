defmodule GsdTracker.Flock do
  use Ash.Resource,
    domain: GsdTracker.Ash,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "flocks"
    repo GsdTracker.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :center_location, AshGeo.Geometry do
      allow_nil? true
    end

    attribute :member_count, :integer do
      default 0
      allow_nil? false
    end
  end

  relationships do
    has_many :members, GsdTracker.GSD
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:center_location, :member_count],
      update: [:center_location, :member_count]
    ]
  end
end
