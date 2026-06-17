defmodule DailyOutput.Markdown do
  @moduledoc """
  Renders the small slice of Markdown that AI-generated focus tips and feedback
  use into safe HTML: `**bold**`, `*italic*`/`_italic_`, `` `code` `` and `>` blockquotes.

  This is intentionally tiny — we control the input (our own prompts), so we only
  support the handful of constructs we actually emit rather than pulling in a full
  CommonMark parser. All input is HTML-escaped before any formatting is applied, so
  the result is always safe to render with `raw/1`.
  """

  @doc """
  Converts `text` to an HTML-safe tuple suitable for direct interpolation in HEEx.

  Returns `{:safe, html}`. `nil` renders as an empty string.
  """
  def to_html(nil), do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    html =
      text
      |> String.split("\n")
      |> group_blocks()
      |> Enum.map_join("", &render_block/1)

    {:safe, html}
  end

  # Groups raw lines into `{:quote, lines}` and `{:para, lines}` blocks. Consecutive
  # `>` lines form one blockquote; consecutive non-blank lines form one paragraph;
  # blank lines separate blocks.
  defp group_blocks(lines) do
    lines
    |> Enum.reduce([], fn line, blocks ->
      cond do
        blockquote_line?(line) -> push(blocks, :quote, strip_quote(line))
        String.trim(line) == "" -> push_break(blocks)
        true -> push(blocks, :para, line)
      end
    end)
    |> Enum.reject(&(&1 == :break))
    |> Enum.reverse()
    |> Enum.map(fn {kind, lines} -> {kind, Enum.reverse(lines)} end)
  end

  # A blank line closes the current block so the next one starts fresh.
  defp push_break([:break | _] = blocks), do: blocks
  defp push_break(blocks), do: [:break | blocks]

  defp push([{kind, lines} | rest], kind, line), do: [{kind, [line | lines]} | rest]
  defp push(blocks, kind, line), do: [{kind, [line]} | blocks]

  defp blockquote_line?(line), do: Regex.match?(~r/^\s*>\s?/, line)
  defp strip_quote(line), do: Regex.replace(~r/^\s*>\s?/, line, "")

  defp render_block({:quote, lines}), do: "<blockquote>#{render_lines(lines)}</blockquote>"
  defp render_block({:para, lines}), do: "<p>#{render_lines(lines)}</p>"

  defp render_lines(lines) do
    lines
    |> Enum.map_join("<br/>", &(&1 |> escape() |> inline()))
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Inline formatting, applied to already-escaped text. Code spans first so their
  # contents are not re-interpreted, then bold (two stars) before italic (one).
  defp inline(text) do
    text
    |> replace(~r/`([^`]+)`/, "<code>", "</code>")
    |> replace(~r/\*\*([^*]+)\*\*/, "<strong>", "</strong>")
    |> replace(~r/\*([^*]+)\*/, "<em>", "</em>")
    |> replace(~r/_([^_]+)_/, "<em>", "</em>")
  end

  defp replace(text, regex, open, close) do
    Regex.replace(regex, text, fn _, inner -> open <> inner <> close end)
  end
end
