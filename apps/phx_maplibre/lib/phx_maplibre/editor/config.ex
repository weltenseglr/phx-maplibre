defmodule PhxMaplibre.Editor.Config do
  @moduledoc "Configuration for the explicitly enabled shared Terra Draw editor."

  @drawing_modes ~w(point marker linestring polyline polygon rectangle circle freehand freehand-linestring angled-rectangle sensor sector text)
  @control_modes ~w(render select delete-selection delete undo redo download)

  def drawing_modes, do: @drawing_modes
  def modes, do: @drawing_modes ++ @control_modes

  def normalize(config) when is_map(config) do
    config = Map.new(config, fn {key, value} -> {to_string(key), value} end)
    modes = Map.get(config, "modes", modes()) |> Enum.map(&to_string/1) |> Enum.uniq()
    unless Enum.all?(modes, &(&1 in modes())), do: raise(ArgumentError, "Unsupported editor mode")

    fields = Map.get(config, "fields", ["name", "color"]) |> Enum.map(&to_string/1) |> Enum.uniq()

    unless Enum.all?(fields, &(&1 in ["name", "color"])),
      do: raise(ArgumentError, "Editor fields must be name or color")

    control = Map.get(config, "control", "draw")

    unless control in ["draw", "measure"],
      do: raise(ArgumentError, "Editor control must be draw or measure")

    interval = Map.get(config, "update_interval_ms", 500)

    unless is_integer(interval) and interval in 25..2000,
      do: raise(ArgumentError, "Editor interval must be between 25 and 2000 ms")

    config
    |> Map.put("modes", modes)
    |> Map.put("fields", fields)
    |> Map.put("control", control)
    |> Map.put_new("control_options", %{"open" => true})
    |> Map.put("update_interval_ms", interval)
  end
end
