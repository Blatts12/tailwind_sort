defmodule TailwindSort.DataType do
  @moduledoc false
  # Port of tailwindcss/src/utils/infer-data-type.ts. Tailwind asks for the first matching type
  # from a list. We return the full set of matching types instead, and the generated data maps
  # that set to how each utility behaves.

  alias TailwindSort.Text

  @num "[+-]?\\d*\\.?\\d+(?:[eE][+-]?\\d+)?"
  @length_units ~w(cm mm Q in pc pt px em ex ch rem lh rlh vw vh vmin vmax vb vi svw svh lvw lvh dvw dvh cqw cqh cqi cqb cqmin cqmax)
  @is_number Regex.compile!("^#{@num}$")
  @is_percentage Regex.compile!("^#{@num}%$")
  @is_fraction Regex.compile!("^#{@num}\\s*/\\s*#{@num}$")
  @is_length Regex.compile!("^#{@num}(#{Enum.join(@length_units, "|")})$")
  @is_angle Regex.compile!("^#{@num}(deg|rad|grad|turn)$")
  @is_vector Regex.compile!("^#{@num} +#{@num} +#{@num}$")
  @math_fns ~w(calc min max clamp mod rem sin cos tan asin acos atan atan2 pow sqrt hypot log exp round)
  @color_fn ~r/^(rgba?|hsla?|hwb|color|(ok)?(lab|lch)|light-dark|color-mix|--alpha)\(/i
  @generic_names ~w(serif sans-serif monospace cursive fantasy system-ui ui-serif ui-sans-serif ui-monospace ui-rounded math emoji fangsong)
  @absolute_sizes ~w(xx-small x-small small medium large x-large xx-large xxx-large)

  @types ~w(color length percentage ratio number integer url position bg-size line-width image family-name generic-name absolute-size relative-size angle vector)

  @doc "Returns the set of data types `value` satisfies. A `var(...)` value skips inference and returns `:var`."
  def infer_types(value, named_colors) do
    if String.starts_with?(value, "var(") do
      :var
    else
      for t <- @types, type_matches?(t, value, named_colors), into: MapSet.new(), do: t
    end
  end

  defp type_matches?("color", v, named), do: color_value?(v, named)
  defp type_matches?("length", v, _), do: length_value?(v)
  defp type_matches?("percentage", v, _), do: percentage_value?(v)
  defp type_matches?("ratio", v, _), do: Regex.match?(@is_fraction, v) or math_function_call?(v)
  defp type_matches?("number", v, _), do: number_value?(v)
  defp type_matches?("integer", v, _), do: Regex.match?(~r/^(0|[1-9]\d*)$/, v)
  defp type_matches?("url", v, _), do: url_value?(v)
  defp type_matches?("position", v, _), do: position_value?(v)
  defp type_matches?("bg-size", v, _), do: bg_size_value?(v)

  defp type_matches?("line-width", v, _),
    do:
      Enum.all?(
        Text.split_top_level(v, " "),
        &(length_value?(&1) or number_value?(&1) or &1 in ~w(thin medium thick))
      )

  defp type_matches?("image", v, _), do: image_value?(v)
  defp type_matches?("family-name", v, _), do: family_name_value?(v)
  defp type_matches?("generic-name", v, _), do: v in @generic_names
  defp type_matches?("absolute-size", v, _), do: v in @absolute_sizes
  defp type_matches?("relative-size", v, _), do: v in ~w(larger smaller)
  defp type_matches?("angle", v, _), do: Regex.match?(@is_angle, v)
  defp type_matches?("vector", v, _), do: Regex.match?(@is_vector, v)

  def color_value?(<<?#, _::binary>>, _), do: true

  def color_value?(v, named),
    do: Regex.match?(@color_fn, v) or MapSet.member?(named, String.downcase(v))

  defp math_function_call?(v),
    do: String.contains?(v, "(") and Enum.any?(@math_fns, &String.contains?(v, &1 <> "("))

  defp number_value?(v), do: Regex.match?(@is_number, v) or math_function_call?(v)
  defp percentage_value?(v), do: Regex.match?(@is_percentage, v) or math_function_call?(v)

  defp length_value?(v),
    do:
      Regex.match?(@is_length, v) or Regex.match?(~r/^(--spacing)\(/i, v) or
        math_function_call?(v)

  defp url_value?(v), do: Regex.match?(~r/^url\(.*\)$/s, v)

  defp image_value?(v) do
    v
    |> Text.split_top_level(",")
    |> Enum.reduce_while(0, fn part, n ->
      cond do
        String.starts_with?(part, "var(") -> {:cont, n}
        url_value?(part) -> {:cont, n + 1}
        Regex.match?(~r/^(repeating-)?(conic|linear|radial)-gradient\(/, part) -> {:cont, n + 1}
        Regex.match?(~r/^(?:element|image|cross-fade|image-set)\(/, part) -> {:cont, n + 1}
        true -> {:halt, :no}
      end
    end)
    |> then(&(&1 != :no and &1 > 0))
  end

  defp family_name_value?(v) do
    v
    |> Text.split_top_level(",")
    |> Enum.reduce_while(0, fn part, n ->
      cond do
        match?(<<c, _::binary>> when c in ?0..?9, part) -> {:halt, :no}
        String.starts_with?(part, "var(") -> {:cont, n}
        true -> {:cont, n + 1}
      end
    end)
    |> then(&(&1 != :no and &1 > 0))
  end

  defp position_value?(v) do
    v
    |> Text.split_top_level(" ")
    |> Enum.reduce_while(0, fn part, n ->
      cond do
        part in ~w(center top right bottom left) -> {:cont, n + 1}
        String.starts_with?(part, "var(") -> {:cont, n}
        length_value?(part) or percentage_value?(part) -> {:cont, n + 1}
        true -> {:halt, :no}
      end
    end)
    |> then(&(&1 != :no and &1 > 0))
  end

  defp bg_size_value?(v) do
    v
    |> Text.split_top_level(",")
    |> Enum.reduce_while(0, fn size, n ->
      values = Text.split_top_level(size, " ")

      cond do
        size in ~w(cover contain) ->
          {:cont, n + 1}

        length(values) not in [1, 2] ->
          {:halt, :no}

        Enum.all?(values, &(&1 == "auto" or length_value?(&1) or percentage_value?(&1))) ->
          {:cont, n + 1}

        true ->
          {:cont, n}
      end
    end)
    |> then(&(&1 != :no and &1 > 0))
  end
end
