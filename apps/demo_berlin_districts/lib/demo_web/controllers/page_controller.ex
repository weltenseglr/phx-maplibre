defmodule DemoWeb.PageController do
  use DemoWeb, :controller

  def redirect_to_map(conn, _params) do
    redirect(conn, to: ~p"/map")
  end
end
