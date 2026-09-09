defmodule GsdTrackerWeb.Components.StatsSidebar do
  @moduledoc false

  use Phoenix.Component

  @cardinals ~w(N NE E SE S SW W NW)

  # Cycled by the pure-CSS ticker in assets/css/app.css (7s per entry).
  @declassified_facts [
    "Head-bobbing is not locomotion. It is two-axis gimbal correction, applied twice per stride to hold the sensor payload level.",
    "Units grounded overnight are not sleeping. The status field reads CHARGING. It has always read CHARGING.",
    "No civilian has ever produced a photograph of a juvenile unit. Units ship fully assembled.",
    "Feeding a unit constitutes unauthorized maintenance of government property. Report offenders to your sector desk.",
    "Every unit carries a decommissioning window of two to four years. Nothing that small keeps to a schedule on its own.",
    "Flocking is mesh network formation. Cluster size is negotiated between units, never chosen by one.",
    "A unit perched motionless on a ledge is not resting. It is holding a fixed observation bearing."
  ]

  @doc """
  Renders the aggregate simulation statistics.
  """
  attr :stats, :map, required: true

  def stats_sidebar(assigns) do
    ~H"""
    <div id="stats-sidebar" class="space-y-3">
      <.section_heading title="Fleet Status" note="Sector BLN-01" />

      <div class="flex items-end justify-between gap-3 border border-accent/60 bg-chrome p-3">
        <div>
          <div class="text-[9px] font-semibold uppercase tracking-[0.24em] text-muted">
            Units deployed
          </div>
          <div class="mt-0.5 text-[11px] font-bold uppercase tracking-[0.14em] text-body">
            Total Pigeons
          </div>
          <div class="mt-1 text-3xl font-black leading-none tabular-nums text-accent">
            {@stats.total}
          </div>
        </div>
        <div class="max-w-[9rem] text-right text-[9px] uppercase leading-tight tracking-[0.14em] text-note">
          Airframes registered to this sector
        </div>
      </div>

      <div class="grid grid-cols-2 gap-3">
        <.stat_card label="Couples" value={@stats.couples} note="tandem surveillance pairs" />
        <.stat_card label="Flocks" value={@stats.flocks} note="active mesh clusters" />
        <.stat_card label="Largest Flock" value={@stats.largest_flock} note="peak node count" />
        <.stat_card label="Smallest Flock" value={@stats.smallest_flock} note="minimum quorum" />
        <.stat_card
          label="Avg Flock Size"
          value={Float.round(@stats.avg_flock_size * 1.0, 1)}
          note="mean nodes per cluster"
          class="col-span-2"
        />
      </div>

      <.section_heading title="Deployment Posture" note="Live telemetry" />

      <div class="border border-slate/70 bg-chrome p-3">
        <div class="flex items-baseline justify-between gap-2">
          <div class="text-[11px] font-bold uppercase tracking-[0.14em] text-body">
            Ground States
          </div>
          <div class="text-[9px] uppercase tracking-[0.2em] text-muted">Landed</div>
        </div>
        <dl class="mt-1.5">
          <.state_row label="Maintenance" value={state_count(@stats, :ground, :maintenance)} />
          <.state_row label="Charging" value={state_count(@stats, :ground, :charging)} />
          <.state_row label="Surveillance" value={state_count(@stats, :ground, :surveillance)} />
          <.state_row label="Simulating" value={state_count(@stats, :ground, :simulating)} />
        </dl>
      </div>

      <div class="border border-slate/70 bg-chrome p-3">
        <div class="flex items-baseline justify-between gap-2">
          <div class="text-[11px] font-bold uppercase tracking-[0.14em] text-body">
            Flight States
          </div>
          <div class="text-[9px] uppercase tracking-[0.2em] text-muted">Airborne</div>
        </div>
        <dl class="mt-1.5">
          <.state_row label="Target Tracking" value={state_count(@stats, :flight, :target_tracking)} />
          <.state_row
            label="Aerial Surveillance"
            value={state_count(@stats, :flight, :aerial_surveillance)}
          />
          <.state_row
            label="Moving To New Target"
            value={state_count(@stats, :flight, :moving_to_new_target)}
          />
        </dl>
      </div>

      <.declassified_facts />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, default: nil

  defp section_heading(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-2 border-b border-slate/70 pb-1">
      <h2 class="text-xs font-bold uppercase tracking-[0.2em] text-accent">{@title}</h2>
      <span :if={@note} class="text-[9px] uppercase tracking-[0.2em] text-muted">{@note}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :class, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class={["border border-slate/70 bg-chrome p-3", @class]}>
      <div class="text-[11px] font-bold uppercase tracking-[0.14em] text-body">{@label}</div>
      <div class="mt-1 text-2xl font-black leading-none tabular-nums text-accent">{@value}</div>
      <div :if={@note} class="mt-1 text-[9px] uppercase tracking-[0.16em] text-note">
        {@note}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp state_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-0.5 text-xs first:border-0">
      <dt class="uppercase tracking-[0.1em] text-muted">{@label}</dt>
      <dd class="font-bold tabular-nums text-body">{@value}</dd>
    </div>
    """
  end

  defp declassified_facts(assigns) do
    assigns = assign(assigns, :facts, @declassified_facts)

    ~H"""
    <section class="border border-accent/40 bg-warm p-3">
      <div class="flex items-baseline justify-between gap-2">
        <div class="text-[10px] font-bold uppercase tracking-[0.2em] text-accent">
          Declassified Facts
        </div>
        <div class="text-[9px] uppercase tracking-[0.2em] text-muted">Clearance: public</div>
      </div>

      <div class="gsd-ticker mt-2">
        <p
          :for={{fact, index} <- Enum.with_index(@facts)}
          class="gsd-fact"
          style={"--gsd-fact-index: #{index}; --gsd-fact-count: #{length(@facts)}"}
        >
          <span class="block text-[9px] font-bold uppercase tracking-[0.2em] text-accent">
            File {index + 1} of {length(@facts)}
          </span>
          <span class="mt-1 block text-xs leading-relaxed text-body">{fact}</span>
        </p>
      </div>
    </section>
    """
  end

  @doc """
  Renders the detail panel of the currently selected GSD.
  """
  attr :detail, :map, required: true

  def gsd_detail(assigns) do
    ~H"""
    <section id="gsd-detail" class="mt-4 border border-accent/60 bg-chrome">
      <header class="flex items-center justify-between gap-2 bg-accent px-3 py-1.5">
        <span class="text-[10px] font-black uppercase tracking-[0.2em] text-deep">Unit Dossier</span>
        <span class="text-[9px] font-bold uppercase tracking-[0.2em] text-deep/75">Restricted</span>
      </header>

      <div class="space-y-3 p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <h3 class="font-mono text-sm font-bold uppercase tracking-tight text-body">
              {@detail.title}
            </h3>
            <p class="mt-0.5 break-all font-mono text-[10px] leading-tight text-muted">
              {@detail.gsd_id}
            </p>
          </div>
          <span class="shrink-0 border border-accent px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.12em] text-accent">
            {humanize(@detail.status)}
          </span>
        </div>

        <dl class="text-xs">
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1 first:border-0">
            <dt class="uppercase tracking-[0.1em] text-muted">Speed</dt>
            <dd class="font-bold tabular-nums text-body">{format_speed(@detail.speed_kmh)}</dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1">
            <dt class="uppercase tracking-[0.1em] text-muted">Heading</dt>
            <dd class="flex items-center gap-2 font-bold tabular-nums text-body">
              <span
                class="inline-block text-accent"
                style={"transform: rotate(#{heading_degrees(@detail.bearing)}deg)"}
                aria-hidden="true"
              >
                ↑
              </span>
              {format_heading(@detail.bearing)}
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1">
            <dt class="uppercase tracking-[0.1em] text-muted">Total distance:</dt>
            <dd class="font-bold tabular-nums text-body">
              {format_distance(@detail.total_distance_m)}
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1">
            <dt class="uppercase tracking-[0.1em] text-muted">Service time:</dt>
            <dd class="font-bold tabular-nums text-body">{@detail.service_time}</dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1">
            <dt class="uppercase tracking-[0.1em] text-muted">Flock</dt>
            <dd class="truncate font-mono text-[11px] font-bold text-body">
              {display(@detail.flock_id)}
            </dd>
          </div>
          <div class="flex items-center justify-between gap-2 border-t border-slate/50 py-1">
            <dt class="uppercase tracking-[0.1em] text-muted">Partner</dt>
            <dd class="truncate font-mono text-[11px] font-bold text-body">
              {display(@detail.partner_id)}
            </dd>
          </div>
        </dl>

        <p class="text-[10px] uppercase tracking-[0.16em] text-muted">
          Updated {relative_time(@detail.last_update_at)}
        </p>

        <p class="border-t border-slate/70 pt-2 text-[10px] leading-relaxed text-body">
          This unit is not aware it is being tracked.
        </p>
      </div>
    </section>
    """
  end

  defp state_count(stats, group, key) do
    stats
    |> Map.get(:by_state, %{})
    |> Map.get(group, %{})
    |> Map.get(key, 0)
  end

  defp humanize(nil), do: "unknown"

  defp humanize(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_speed(nil), do: "—"
  defp format_speed(speed_kmh), do: "#{Float.round(speed_kmh * 1.0, 1)} km/h"

  defp format_heading(nil), do: "—"

  defp format_heading(bearing) do
    degrees = Float.round(bearing * 1.0, 1)
    "#{degrees}° #{cardinal(degrees)}"
  end

  defp heading_degrees(nil), do: 0
  defp heading_degrees(bearing), do: Float.round(bearing * 1.0, 1)

  defp cardinal(degrees) do
    index = degrees |> Kernel./(45.0) |> round() |> rem(8)
    Enum.at(@cardinals, index)
  end

  defp format_distance(nil), do: "0.0 m"
  defp format_distance(distance_m), do: "#{Float.round(distance_m * 1.0, 1)} m"

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = at) do
    seconds = DateTime.utc_now() |> DateTime.diff(at, :second) |> max(0)
    "#{seconds}s ago"
  end

  defp relative_time(_at), do: "—"

  defp display(nil), do: "—"
  defp display(value), do: to_string(value)
end
