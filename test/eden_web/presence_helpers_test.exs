defmodule EdenWeb.PresenceHelpersTest do
  use ExUnit.Case, async: true

  alias EdenWeb.PresenceHelpers, as: H

  describe "status_text_color_var/1 (#364)" do
    test "maps each status to its as-TEXT (-strong) token, so a status label clears WCAG AA" do
      # The bright fill tokens (status_color_var) fail 4.5:1 as on-surface text; the label must use
      # the darkened/lightened -strong tiers instead.
      assert H.status_text_color_var("online") == "--ed-online-strong"
      assert H.status_text_color_var("away") == "--ed-warning-strong"
      assert H.status_text_color_var("dnd") == "--ed-danger-strong"
      assert H.status_text_color_var(nil) == "--ed-muted"
      assert H.status_text_color_var("anything-else") == "--ed-muted"
    end

    test "the fill token helper stays the bright tier (for the presence DOT, not text)" do
      assert H.status_color_var("online") == "--ed-online"
      assert H.status_color_var("dnd") == "--ed-dnd"
    end
  end
end
