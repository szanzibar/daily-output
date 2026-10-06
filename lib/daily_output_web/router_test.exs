defmodule DailyOutputWeb.RouterTest do
  use DailyOutputWeb.ConnCase, async: true

  test "pages only run our own scripts", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self';"
    refute csp =~ "script-src"
  end
end
