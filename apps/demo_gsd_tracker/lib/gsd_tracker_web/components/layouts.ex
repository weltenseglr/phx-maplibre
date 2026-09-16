defmodule GsdTrackerWeb.Layouts do
  @moduledoc false

  use GsdTrackerWeb, :html

  embed_templates "layouts/*"

  @doc """
  The app layout: a thin oversight-portal shell around the page content.
  """
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh w-full flex-col bg-ink">
      <header class="flex shrink-0 flex-wrap items-center justify-between gap-x-6 gap-y-1 border-b border-accent/60 bg-chrome px-4 py-2.5">
        <div class="flex items-baseline gap-3">
          <span class="text-lg font-black uppercase leading-none tracking-tighter text-accent sm:text-xl">
            GSD Tracker
          </span>
          <span class="text-[9px] font-medium uppercase tracking-[0.22em] text-muted sm:text-[10px]">
            Civilian Oversight Portal — Berlin Sector
          </span>
        </div>

        <div class="flex items-center gap-5">
          <nav
            aria-label="Primary navigation"
            class="flex items-center gap-3 text-[10px] font-bold uppercase tracking-[0.12em]"
          >
            <a
              class="text-muted underline decoration-slate underline-offset-4 hover:text-accent"
              href={~p"/"}
            >Tracker</a>
            <a
              class="text-muted underline decoration-slate underline-offset-4 hover:text-accent"
              href={~p"/about"}
            >About this demo</a>
          </nav>

          <span
            id="gsd-connection-status"
            class="gsd-connection-status is-offline flex items-center gap-2"
            role="status"
            aria-live="polite"
            phx-hook="ConnectionStatus"
            data-connection="offline"
          >
            <span class="gsd-live-dot inline-block size-2 rounded-full" aria-hidden="true"></span>
            <span class="gsd-status-live text-[10px] font-bold uppercase tracking-[0.2em]">Live</span>
            <span class="gsd-status-offline text-[10px] font-bold uppercase tracking-[0.2em]">Offline</span>
          </span>

          <a
            href="https://pigeonsarentreal.co.uk"
            target="_blank"
            rel="noopener"
            title="Birds aren't real."
            class="hidden text-[10px] uppercase tracking-[0.12em] text-muted underline decoration-slate underline-offset-4 hover:text-accent md:inline"
          >
            an homage to pigeonsarentreal.co.uk
          </a>
        </div>
      </header>

      <main class="flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the info/error flash messages.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
