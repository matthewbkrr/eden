defmodule EdenWeb.MarkupTest do
  use ExUnit.Case, async: true

  alias EdenWeb.Markup

  defp html(text) do
    {:safe, iodata} = Markup.to_iodata(text)
    IO.iodata_to_binary(iodata)
  end

  describe "to_iodata/1 inline marks" do
    test "bold, italic (both markers), and code" do
      assert html("a **b** c") == "a <strong>b</strong> c"
      assert html("a *b* c") == "a <em>b</em> c"
      assert html("a _b_ c") == "a <em>b</em> c"
      assert html("a `b` c") == "a <code>b</code> c"
    end

    test "bold wins over italic" do
      assert html("**x**") == "<strong>x</strong>"
    end

    test "lone / unclosed markers render literally" do
      assert html("a * b") == "a * b"
      assert html("*foo") == "*foo"
      assert html("100% done") == "100% done"
    end

    test "emphasis can't hug whitespace; underscores stay out of words" do
      assert html("a * b *") == "a * b *"
      assert html("snake_case_name") == "snake_case_name"
    end

    test "bare URLs become safe links, surrounding text preserved" do
      out = html("see https://example.com/x now")
      assert out =~ ~s(<a class="ed-link" href="https://example.com/x")
      assert out =~ ~s(rel="noopener noreferrer">https://example.com/x</a>)
      assert out =~ "see "
      assert out =~ " now"
    end
  end

  describe "to_iodata/1 headings" do
    test "#, ##, ### map to heading levels and format their inline content" do
      assert html("# Title") == ~s(<span class="ed-md-h1">Title</span>)
      assert html("## Sub") == ~s(<span class="ed-md-h2">Sub</span>)

      assert html("### Small **bold**") ==
               ~s(<span class="ed-md-h3">Small <strong>bold</strong></span>)
    end

    test "a hash without a following space is not a heading" do
      assert html("#nottag") == "#nottag"
    end
  end

  describe "to_iodata/1 safety" do
    test "all user text is escaped; no injection survives" do
      assert html("<script>alert(1)</script>") ==
               "&lt;script&gt;alert(1)&lt;/script&gt;"

      assert html("**<b>x</b>**") == "<strong>&lt;b&gt;x&lt;/b&gt;</strong>"
      # An attribute-breaking URL is escaped inside the href + text.
      refute html(~s(https://x/"><img>)) =~ ~s(<img>)
    end
  end

  describe "strip/1" do
    test "removes markers for previews" do
      assert Markup.strip("# Title") == "Title"
      assert Markup.strip("a **b** _c_ `d`") == "a b c d"
      assert Markup.strip("plain text") == "plain text"
    end
  end
end
