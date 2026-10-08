# elixir pack_data.exs <terms from extract.mjs> <output .etf>
# About 48k modifier groups share a few hundred tables. ETF and persistent_term both store a repeated
# term once per use, so we keep each table once in `modifier_tables` and point at it by index.

[term_file, etf_file] = System.argv()
{:ok, terms} = :file.consult(String.to_charlist(term_file))
data = Map.new(terms)

tables = data.modifiers |> Map.values() |> Enum.uniq()
index = tables |> Enum.with_index() |> Map.new()

data =
  data
  |> Map.put(:modifiers, Map.new(data.modifiers, fn {group, table} -> {group, Map.fetch!(index, table)} end))
  |> Map.put(:modifier_tables, List.to_tuple(tables))

File.write!(etf_file, :erlang.term_to_binary(data, [:compressed, minor_version: 2]))
