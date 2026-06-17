defmodule DailyOutput.MarkdownTest do
  use ExUnit.Case, async: true

  alias DailyOutput.Markdown

  defp html(text), do: Markdown.to_html(text) |> elem(1)

  test "nil renders as empty string" do
    assert Markdown.to_html(nil) == {:safe, ""}
  end

  test "plain text is wrapped in a paragraph" do
    assert html("hello") == "<p>hello</p>"
  end

  test "bold uses strong" do
    assert html("the **desto** rule") == "<p>the <strong>desto</strong> rule</p>"
  end

  test "italic uses em for both star and underscore" do
    assert html("an *example* here") == "<p>an <em>example</em> here</p>"
    assert html("an _example_ here") == "<p>an <em>example</em> here</p>"
  end

  test "bold is not eaten by italic" do
    assert html("**bold**") == "<p><strong>bold</strong></p>"
  end

  test "inline code is preserved literally" do
    assert html("use `je ... desto`") == "<p>use <code>je ... desto</code></p>"
  end

  test "blockquote lines become a blockquote block" do
    assert html("> Je mehr, desto besser.") ==
             "<blockquote>Je mehr, desto besser.</blockquote>"
  end

  test "consecutive quote lines merge into one blockquote" do
    assert html("> line one\n> line two") ==
             "<blockquote>line one<br/>line two</blockquote>"
  end

  test "paragraph and blockquote can coexist" do
    assert html("The rule:\n> example") ==
             "<p>The rule:</p><blockquote>example</blockquote>"
  end

  test "html is escaped before formatting" do
    assert html("a < b & c > d") == "<p>a &lt; b &amp; c &gt; d</p>"
  end

  test "escaping cannot be bypassed by formatting" do
    assert html("**<script>**") == "<p><strong>&lt;script&gt;</strong></p>"
  end

  test "german typographic quotes pass through untouched" do
    assert html("„je … desto\"") == "<p>„je … desto&quot;</p>"
  end

  test "blank lines separate paragraphs" do
    assert html("first\n\nsecond") == "<p>first</p><p>second</p>"
  end
end
