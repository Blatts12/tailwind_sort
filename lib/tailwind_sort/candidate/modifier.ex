defmodule TailwindSort.Candidate.Modifier do
  @moduledoc """
  Parses the modifier after a `/`, like the `50` in `bg-red-500/50` or the `name` in `group-hover/name`.

  This is a port of `parseModifier` from `tailwindcss/src/candidate.ts`.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.Text
  alias TailwindSort.Text.ArbitraryValue

  @doc "Port of parseModifier. Returns `{:named, v}`, `{:arbitrary, v}`, `{:var, v}` or nil."
  @spec parse_modifier(modifier :: String.t()) :: Candidate.modifier()
  def parse_modifier("[" <> _ = m) do
    if String.ends_with?(m, "]") do
      with v when v != nil <- ArbitraryValue.decode_valid_arbitrary_value(binary_part(m, 1, byte_size(m) - 2)),
           do: {:arbitrary, v}
    else
      parse_named_modifier(m)
    end
  end

  def parse_modifier("(" <> _ = m) do
    if String.ends_with?(m, ")") do
      inner = binary_part(m, 1, byte_size(m) - 2)

      if String.starts_with?(inner, "--") and ArbitraryValue.valid_arbitrary_value?(inner),
        do: {:var, "var(#{inner})"}
    else
      parse_named_modifier(m)
    end
  end

  def parse_modifier(m), do: parse_named_modifier(m)

  defp parse_named_modifier(m), do: if(Text.named_value?(m), do: {:named, m})
end
