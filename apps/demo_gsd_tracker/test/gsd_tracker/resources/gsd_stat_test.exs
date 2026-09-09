defmodule GsdTracker.Resources.GSDStatTest do
  use GsdTracker.DataCase, async: true

  test "bulk upserts on duplicate gsd_id and timestamp" do
    gsd =
      GsdTracker.GSD
      |> Ash.Changeset.for_create(:create, %{
        commissioning_date: DateTime.utc_now() |> DateTime.truncate(:second),
        status: :surveillance
      })
      |> Ash.create!(domain: GsdTracker.Ash)

    base = ~U[2026-08-04 12:00:00.000000Z]

    inputs =
      for index <- 0..99 do
        %{
          timestamp: DateTime.add(base, index, :second),
          gsd_id: gsd.id,
          status: :surveillance,
          movement_vector: %{lat: index, lng: index},
          speed_kmh: Decimal.new("70.0")
        }
      end

    result =
      Ash.bulk_create!(inputs, GsdTracker.GSDStat, :bulk_upsert,
        domain: GsdTracker.Ash,
        return_records?: true
      )

    assert result.status == :success
    assert length(result.records) == 100

    duplicate = [
      %{
        timestamp: base,
        gsd_id: gsd.id,
        status: :charging,
        movement_vector: %{lat: 999, lng: 999},
        speed_kmh: Decimal.new("12.5")
      }
    ]

    result =
      Ash.bulk_create!(duplicate, GsdTracker.GSDStat, :bulk_upsert,
        domain: GsdTracker.Ash,
        return_records?: true
      )

    assert result.status == :success

    stats =
      GsdTracker.GSDStat
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(timestamp: :asc)
      |> Ash.read!(domain: GsdTracker.Ash)
      |> Enum.filter(&(&1.gsd_id == gsd.id))

    assert length(stats) == 100
    assert hd(stats).status == :charging
    assert hd(stats).movement_vector == %{"lat" => 999, "lng" => 999}
    assert Decimal.eq?(hd(stats).speed_kmh, Decimal.new("12.5"))
  end
end
