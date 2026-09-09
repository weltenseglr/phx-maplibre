defmodule GsdTracker.Ash do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource GsdTracker.LandCover
    resource GsdTracker.GSD
    resource GsdTracker.GSDStat
    resource GsdTracker.Flock
  end
end
