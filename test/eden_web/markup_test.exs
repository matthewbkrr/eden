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

  describe "mentions (#576)" do
    defp mention(handle, username), do: %{handle: handle, user: %{username: username}}

    defp render(text, mentions \\ []) do
      {:safe, io} = Markup.to_iodata(text, mentions)
      IO.iodata_to_binary(io)
    end

    test "a resolved handle becomes a chip labelled with the person's CURRENT name" do
      html = render("@bob ping", [mention("bob", "robert")])

      assert html =~ ~s(class="ed-mention")
      assert html =~ "@robert", "the chip carries the current handle, not the one typed"
      refute html =~ "@bob ", "the typed handle must not survive as text next to the chip"
    end

    test "an unresolved handle stays plain text" do
      assert render("@nobody hi") == "@nobody hi"
    end

    test "a handle inside code is left alone" do
      html = render("`@bob` and @bob", [mention("bob", "bob")])

      assert html =~ "<code>@bob</code>", "code spans are literal"
      assert html =~ ~s(class="ed-mention"), "the one outside the code span is still a chip"
    end

    test "the chip escapes what it renders" do
      html = render("@xy", [mention("xy", ~s(a"><script>))])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
