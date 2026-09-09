defmodule DemoWeb.PageControllerTest do
  use DemoWeb.ConnCase

  test "GET / redirects to /map", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/map"
  end
end
