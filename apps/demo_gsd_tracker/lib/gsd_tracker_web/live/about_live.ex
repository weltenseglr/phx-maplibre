defmodule GsdTrackerWeb.AboutLive do
  @moduledoc false

  use GsdTrackerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "About this demo")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="gsd-scroll flex-1 overflow-y-auto px-4 py-8 sm:px-8 lg:px-12">
        <article class="mx-auto max-w-3xl space-y-8">
          <header class="space-y-3 border-b border-accent/50 pb-6">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-accent">About the demo</p>
            <h1 class="text-3xl font-black tracking-tight text-body sm:text-4xl">
              A pigeon-shaped learning lab
            </h1>
            <p class="text-lg leading-8 text-muted">
              A playful real-time map with a serious purpose: learning the Erlang and Elixir ecosystem
              by building something alive enough to be interesting.
            </p>
          </header>

          <section class="space-y-4 leading-7 text-body">
            <p>
              GSD Tracker is a live map of simulated “Government Surveillance Drone” pigeons moving
              around Berlin. The joke is an homage to <a
                class="text-accent underline underline-offset-4"
                href="https://pigeonsarentreal.co.uk"
                target="_blank"
                rel="noopener"
              >Birds Aren’t Real</a>,
              but the app is a place to learn the Erlang/Elixir ecosystem by building a recognizable,
              stateful, real-time application from end to end.
            </p>
            <p>
              It is an experiment in getting comfortable with the tools rather than a claim to model
              real birds. A deliberately silly subject keeps the work approachable while the system is
              substantial enough to expose real engineering questions: what happens when a map, a
              database, background processes, and many browsers all change together?
            </p>
          </section>

          <section class="space-y-4">
            <h2 class="text-xl font-bold text-accent">What it explores</h2>
            <ul class="list-disc space-y-3 pl-5 leading-7 text-body marker:text-accent">
              <li>
                <strong>Erlang/OTP:</strong>
                supervised processes, message passing, fault isolation, and long-running simulation work.
              </li>
              <li>
                <strong>Phoenix and LiveView:</strong>
                server-rendered, real-time UI updates without turning every interaction into a bespoke browser-to-server event handler.
              </li>
              <li>
                <strong>Ash, Ecto, and Postgres/PostGIS:</strong>
                resource modelling, persistence, and geographic data.
              </li>
              <li>
                <strong>PubSub and phx_maplibre:</strong>
                map commands and interactions travel as messages, so any BEAM process can drive the interface.
              </li>
              <li>
                <strong>Performance:</strong>
                a flock of thousands of units helps reveal where scheduling, data volume, rendering, database work, and browser updates begin to matter.
              </li>
            </ul>
          </section>

          <section class="space-y-4 border-t border-accent/30 pt-6 leading-7 text-body">
            <h2 class="text-xl font-bold text-accent">Why the pigeons vary</h2>
            <p>
              The simulation intentionally fluctuates rather than following a fixed quota: most pigeons
              are active during the day, some take short charging or maintenance breaks, and a small
              probabilistic fraction remains active at night. Couples are linked on the map, so selecting
              one highlights its partner.
            </p>
          </section>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
