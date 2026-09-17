defmodule PhxMaplibre.Editor.Components do
  @moduledoc false
  use Phoenix.Component

  def editor(assigns) do
    assigns = assign(assigns, :editor_config, PhxMaplibre.Editor.Config.normalize(assigns.config))

    ~H"""
    <section
      id={@id}
      phx-hook="PhxMaplibreEditorHook"
      phx-update="ignore"
      data-map-id={@map_id}
      data-editor-config={Jason.encode!(@editor_config)}
      class={["phx-maplibre-editor", @class]}
      aria-label="Shared feature editor"
    >
      {render_slot(@inner_block)}
      <p data-role="status" aria-live="polite">Connecting…</p>
      <p data-role="presence" aria-live="polite"></p>
      <p data-role="error" role="alert"></p>
      <label>
        Update interval (shared)
        <output data-role="interval-value">{@editor_config["update_interval_ms"]} ms</output>
        <input
          type="range"
          data-role="interval"
          aria-label="Update interval"
          min="25"
          max="2000"
          step="1"
          value={@editor_config["update_interval_ms"]}
          disabled
        />
      </label>
      <label>
        <input
          type="checkbox"
          data-role="interpolation"
          aria-label="Interpolate remote cursors"
          checked
        /> Interpolate remote cursors
      </label>
      <div :if={"name" in @editor_config["fields"]}>
        <label>
          Name
          <input
            type="text"
            data-role="selected-name"
            aria-label="Feature name"
            maxlength="100"
            disabled
          />
        </label>
      </div>
      <div :if={"color" in @editor_config["fields"]}>
        <label>
          Color
          <input
            type="color"
            data-role="selected-color"
            aria-label="Feature color"
            value="#f97316"
            disabled
          />
        </label>
      </div>
      <button :if={@editor_config["fields"] != []} type="button" data-role="apply-properties" disabled>
        Apply properties
      </button>
      <h2>Features</h2>
      <ul data-role="list"></ul>
      <div data-role="details"></div>
    </section>
    """
  end
end
