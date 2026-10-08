defmodule TailwindSort.Stylesheet do
  @moduledoc """
  Reads the parts of your Tailwind v4 entry stylesheet that change class order.

  Those are `@theme` variables, `@custom-variant`, `@utility` and `prefix(...)`. We follow
  local imports like `@import "./file.css"`, but not package imports. JS plugins (`@plugin`)
  and `@config` aren't supported.
  """

  defstruct prefix: nil, theme: [], variants: [], utilities: []

  @type t :: %__MODULE__{
          prefix: String.t() | nil,
          theme: [{:set, String.t(), String.t()} | {:reset, String.t()}],
          variants: [{String.t(), [String.t()]}],
          utilities: [{String.t(), [{String.t(), String.t()}]}]
        }

  @type css_node ::
          {:at, String.t()} | {:decl, String.t(), String.t()} | {:block, String.t(), [css_node()]}

  @spec read_stylesheet(Path.t() | nil) :: t()
  def read_stylesheet(nil), do: %__MODULE__{}

  def read_stylesheet(path) do
    path |> load_css_with_imports([]) |> parse_stylesheet()
  end

  @spec parse_stylesheet(css :: String.t()) :: t()
  def parse_stylesheet(css) do
    nodes = css |> strip_comments() |> parse_css()

    nodes
    |> walk_nodes(%__MODULE__{})
    |> Map.update!(:theme, &Enum.reverse/1)
    |> Map.update!(:variants, &Enum.reverse/1)
    |> Map.update!(:utilities, &Enum.reverse/1)
  end

  defp load_css_with_imports(path, seen) do
    path = Path.expand(path)

    if path in seen do
      ""
    else
      seen = [path | seen]
      text = File.read!(path)

      Regex.replace(~r/@import\s+["'](\.{1,2}\/[^"']+|\/[^"']+)["'][^;]*;/, text, fn _, file ->
        file = Path.join(Path.dirname(path), file)
        if File.exists?(file), do: load_css_with_imports(file, seen), else: ""
      end)
    end
  end

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  defp walk_nodes(nodes, acc), do: Enum.reduce(nodes, acc, &collect_node/2)

  defp collect_node({:at, "@import " <> params}, acc) do
    case Regex.run(~r/prefix\(\s*([a-z]+)\s*\)/, params) do
      [_, prefix] -> %{acc | prefix: prefix}
      nil -> acc
    end
  end

  defp collect_node({:at, "@custom-variant " <> rest}, acc) do
    case Regex.run(~r/^\s*([^\s(]+)\s*\((.*)\)\s*$/s, rest) do
      [_, name, body] ->
        %{acc | variants: [{name, parse_shorthand_selectors(body)} | acc.variants]}

      nil ->
        acc
    end
  end

  defp collect_node({:block, "@theme" <> _, children}, acc) do
    sets =
      for {:decl, "--" <> _ = name, value} <- children do
        name = String.replace(name, "\\", "")

        if value == "initial" and String.ends_with?(name, "-*"),
          do: {:reset, String.trim_trailing(name, "*")},
          else: {:set, name, value}
      end

    %{acc | theme: Enum.reverse(sets, acc.theme)}
  end

  defp collect_node({:block, "@custom-variant " <> name, children}, acc) do
    %{acc | variants: [{String.trim(name), collect_block_selectors(children)} | acc.variants]}
  end

  defp collect_node({:block, "@utility " <> name, children}, acc) do
    %{acc | utilities: [{String.trim(name), collect_decls_bfs(children)} | acc.utilities]}
  end

  defp collect_node({:block, "@layer" <> _, children}, acc), do: walk_nodes(children, acc)
  defp collect_node({:block, "@media" <> _, children}, acc), do: walk_nodes(children, acc)
  defp collect_node(_, acc), do: acc

  defp parse_shorthand_selectors(body) do
    case String.trim(body) do
      "@" <> _ = at_rule -> [at_rule]
      sels -> sels |> TailwindSort.Text.split_top_level(",") |> Enum.map(&String.trim/1)
    end
  end

  defp collect_block_selectors(children) do
    Enum.flat_map(children, fn
      {:block, "@slot" <> _, _} -> []
      {:at, "@slot" <> _} -> []
      {:block, "@" <> _ = prelude, kids} -> [prelude | collect_block_selectors(kids)]
      {:block, prelude, kids} -> [prelude | collect_block_selectors(kids)]
      _ -> []
    end)
  end

  # Collects declarations in breadth first order, like Tailwind's getPropertySort.
  defp collect_decls_bfs(children), do: walk_bfs(children, [], [])

  defp walk_bfs([], [], acc), do: Enum.reverse(acc)
  defp walk_bfs([], next, acc), do: walk_bfs(Enum.reverse(next), [], acc)
  defp walk_bfs([{:decl, p, v} | rest], next, acc), do: walk_bfs(rest, next, [{p, v} | acc])

  defp walk_bfs([{:block, _, kids} | rest], next, acc), do: walk_bfs(rest, Enum.reverse(kids, next), acc)

  defp walk_bfs([_ | rest], next, acc), do: walk_bfs(rest, next, acc)

  @doc false
  @spec parse_css(css :: String.t()) :: [css_node()]
  def parse_css(css) do
    {nodes, _} = parse_nodes(css, [])
    nodes
  end

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

  # Scans until `{`, `}` or `;` at paren depth 0. Strings get skipped as a whole.
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
