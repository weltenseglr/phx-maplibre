defmodule PhxMaplibre.TestSupport.TestLive do
  @moduledoc false
  use Phoenix.LiveView
  use PhxMaplibre.LiveView

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :seen, 0)
    {:ok, PhxMaplibre.LiveView.attach_map(socket, "test-map", pubsub: PhxMaplibre.TestPubSub)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhxMaplibre.Components.map id="test-map" />
    <div id="seen">seen:{@seen}</div>
    """
  end

  # Counts the %Event{}s this LiveView receives as a subscriber, so a test can
  # tell "not subscribed" apart from "message merely never asserted on".
  @impl true
  def handle_info(%PhxMaplibre.Event{}, socket) do
    {:noreply, update(socket, :seen, &(&1 + 1))}
  end

  def handle_info({:run_fast_path, geojson}, socket) do
    {:noreply, PhxMaplibre.set_features(socket, "test-map", geojson)}
  end

  def handle_info({:attach, map_id, opts}, socket) do
    {:noreply, PhxMaplibre.LiveView.attach_map(socket, map_id, opts)}
  end

  def handle_info({:detach, map_id}, socket) do
    {:noreply, PhxMaplibre.LiveView.detach_map(socket, map_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
