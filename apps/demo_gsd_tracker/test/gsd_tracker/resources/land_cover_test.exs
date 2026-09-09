defmodule GsdTracker.Resources.LandCoverTest do
  use GsdTracker.DataCase, async: true

  test "creates and reads water polygons" do
    GsdTracker.LandCover
    |> Ash.Changeset.for_create(:create, %{landuse_type: :water})
    |> Ash.create!(domain: GsdTracker.Ash)

    GsdTracker.LandCover
    |> Ash.Changeset.for_create(:create, %{landuse_type: :residential})
    |> Ash.create!(domain: GsdTracker.Ash)

    waters =
      GsdTracker.LandCover
      |> Ash.Query.for_read(:water_polygons)
      |> Ash.read!(domain: GsdTracker.Ash)

    lands =
      GsdTracker.LandCover
      |> Ash.Query.for_read(:land_polygons)
      |> Ash.read!(domain: GsdTracker.Ash)

    assert Enum.all?(waters, &(&1.landuse_type == :water))
    assert :water in Enum.map(waters, & &1.landuse_type)
    refute :water in Enum.map(lands, & &1.landuse_type)
    assert :residential in Enum.map(lands, & &1.landuse_type)
  end
end
