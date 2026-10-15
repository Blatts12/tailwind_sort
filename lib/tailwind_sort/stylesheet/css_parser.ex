defmodule TailwindSort.Stylesheet.CssParser do
  @moduledoc """
  A small CSS parser that turns a stylesheet into a tree of at-rules, declarations and blocks.

  It knows nothing about Tailwind. `TailwindSort.Stylesheet` reads the Tailwind rules out of
  the tree. Comments go away, and quotes, escapes and parentheses keep `;`, `{` and `}` inside
  them from ending a statement.
  """

  @type css_node ::
          {:at, String.t()} | {:decl, String.t(), String.t()} | {:block, String.t(), [css_node()]}

  @doc "Parses `css` into a list of nodes. `!important` is dropped from declaration values."
  @spec parse_css(css :: String.t()) :: [css_node()]
  def parse_css(css) do
    {nodes, _} = css |> strip_comments() |> parse_nodes([])
    nodes
  end

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  defp parse_nodes(css, acc) do
    case scan_next_token(css, []) do
      {:eof, buf} ->
        {Enum.reverse(push_statement(buf, acc)), ""}

      {:close, buf, rest} ->
        {Enum.reverse(push_statement(buf, acc)), rest}

      {:semi, buf, rest} ->
        parse_nodes(rest, push_statement(buf, acc))

      {:open, prelude, rest} ->
        {kids, rest} = parse_nodes(rest, [])
        parse_nodes(rest, [{:block, String.trim(prelude), kids} | acc])
    end
  end

  defp push_statement(buf, acc) do
    text = String.trim(buf)

    cond do
      text == "" ->
        acc

      String.starts_with?(text, "@") ->
        [{:at, text} | acc]

      true ->
        case :binary.split(text, ":") do
          [p, v] ->
            [
              {:decl, String.trim(p), v |> String.trim() |> String.replace(~r/\s*!important$/, "")}
              | acc
            ]

          _ ->
            acc
        end
    end
  end

  defp scan_next_token(css, buf, depth \\ 0)
  defp scan_next_token(<<>>, buf, _), do: {:eof, IO.iodata_to_binary(buf)}
  defp scan_next_token(<<?{, rest::binary>>, buf, 0), do: {:open, IO.iodata_to_binary(buf), rest}
  defp scan_next_token(<<?}, rest::binary>>, buf, 0), do: {:close, IO.iodata_to_binary(buf), rest}
  defp scan_next_token(<<?;, rest::binary>>, buf, 0), do: {:semi, IO.iodata_to_binary(buf), rest}
  defp scan_next_token(<<?(, rest::binary>>, buf, d), do: scan_next_token(rest, [buf, ?(], d + 1)

  defp scan_next_token(<<?), rest::binary>>, buf, d), do: scan_next_token(rest, [buf, ?)], max(d - 1, 0))

  defp scan_next_token(<<?\\, c, rest::binary>>, buf, d), do: scan_next_token(rest, [buf, ?\\, c], d)

  defp scan_next_token(<<q, rest::binary>>, buf, d) when q in [?", ?'] do
    {str, rest} = take_quoted(rest, q, [q])
    scan_next_token(rest, [buf, str], d)
  end

  defp scan_next_token(<<c, rest::binary>>, buf, d), do: scan_next_token(rest, [buf, c], d)

  defp take_quoted(<<?\\, c, rest::binary>>, q, acc), do: take_quoted(rest, q, [acc, ?\\, c])
  defp take_quoted(<<q, rest::binary>>, q, acc), do: {[acc, q], rest}
  defp take_quoted(<<c, rest::binary>>, q, acc), do: take_quoted(rest, q, [acc, c])
  defp take_quoted(<<>>, _q, acc), do: {acc, <<>>}
end
