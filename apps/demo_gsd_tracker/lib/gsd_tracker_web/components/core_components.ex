defmodule GsdTrackerWeb.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  @doc """
  Renders a single flash message of the given kind, if present.
  """
  attr :flash, :map, default: %{}
  attr :kind, :atom, values: [:info, :error], required: true

  def flash(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, @kind)} class="fixed right-4 top-4 z-50">
      <div class={[
        "border px-4 py-3 text-sm shadow-lg",
        "bg-chrome text-body",
        @kind == :info && "border-accent/60",
        @kind == :error && "border-rose-500/70 text-rose-200"
      ]}>
        {msg}
      </div>
    </div>
    """
  end

  @doc """
  Renders an icon as a styled span. The name is used as the CSS class.
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
