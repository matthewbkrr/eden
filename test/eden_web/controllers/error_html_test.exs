defmodule EdenWeb.ErrorHTMLTest do
  use EdenWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a branded, unescaped 404.html" do
    html = render_to_string(EdenWeb.ErrorHTML, "404", "html", [])
    assert html =~ "<!DOCTYPE html>"
    assert html =~ "Page not found"
    assert html =~ "· ihichat</title>"
  end

  test "renders a branded, unescaped 500.html" do
    html = render_to_string(EdenWeb.ErrorHTML, "500", "html", [])
    assert html =~ "<!DOCTYPE html>"
    assert html =~ "Something went wrong"
  end

  test "falls back to a plain status message for other templates" do
    assert render_to_string(EdenWeb.ErrorHTML, "403", "html", []) == "Forbidden"
  end
end
