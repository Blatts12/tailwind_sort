defmodule TailwindSort.DataType do
  @moduledoc """
  Guesses the CSS data types of an arbitrary value, like `[12px]` or `[#fff]`.

  This is a port of `tailwindcss/src/utils/infer-data-type.ts`, with one change. Tailwind asks
  for the first matching type from a list. We return the full set of matching types instead,
  and the generated data maps that set to how each utility behaves.
  """

  alias TailwindSort.Text

  @length_units ~w(cm mm Q in pc pt px em ex ch rem lh rlh vw vh vmin vmax vb vi svw svh lvw lvh dvw dvh cqw cqh cqi cqb cqmin cqmax)
  @math_fns ~w(calc min max clamp mod rem sin cos tan asin acos atan atan2 pow sqrt hypot log exp round)
  @color_fns ~w(rgb rgba hsl hsla hwb color lab lch oklab oklch light-dark color-mix --alpha)
  @gradient_fns ~w(conic-gradient linear-gradient radial-gradient repeating-conic-gradient repeating-linear-gradient repeating-radial-gradient)
  @image_fns ~w(element image cross-fade image-set)
  @generic_names ~w(serif sans-serif monospace cursive fantasy system-ui ui-serif ui-sans-serif ui-monospace ui-rounded math emoji fangsong)
  @absolute_sizes ~w(xx-small x-small small medium large x-large xx-large xxx-large)

  @types ~w(color length percentage ratio number integer url position bg-size line-width image family-name generic-name absolute-size relative-size angle vector)

  @doc "Returns the set of data types `value` satisfies. A `var(...)` value skips inference and returns `:var`."
  @spec infer_types(value :: String.t(), named_colors :: MapSet.t(String.t())) :: MapSet.t(String.t()) | :var
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
  defp type_matches?("ratio", v, _), do: fraction_value?(v) or math_function_call?(v)
  defp type_matches?("number", v, _), do: number_value?(v)
  defp type_matches?("integer", v, _), do: v == "0" or (not String.starts_with?(v, "0") and Text.digits?(v))
  defp type_matches?("url", v, _), do: url_value?(v)
  defp type_matches?("position", v, _), do: position_value?(v)
  defp type_matches?("bg-size", v, _), do: bg_size_value?(v)

  defp type_matches?("line-width", v, _),
    do: Enum.all?(Text.split_top_level(v, " "), &(length_value?(&1) or number_value?(&1) or &1 in ~w(thin medium thick)))

  defp type_matches?("image", v, _), do: image_value?(v)
  defp type_matches?("family-name", v, _), do: family_name_value?(v)
  defp type_matches?("generic-name", v, _), do: v in @generic_names
  defp type_matches?("absolute-size", v, _), do: v in @absolute_sizes
  defp type_matches?("relative-size", v, _), do: v in ~w(larger smaller)
  defp type_matches?("angle", v, _), do: match?({:ok, unit} when unit in ~w(deg rad grad turn), take_number(v))
  defp type_matches?("vector", v, _), do: vector_value?(v)

  @spec color_value?(value :: String.t(), named_colors :: MapSet.t(String.t())) :: boolean()
  def color_value?(<<?#, _::binary>>, _), do: true

  def color_value?(v, named), do: lowercase_function_name(v) in @color_fns or MapSet.member?(named, String.downcase(v))

  defp math_function_call?(v), do: String.contains?(v, "(") and Enum.any?(@math_fns, &String.contains?(v, &1 <> "("))

  defp number_value?(v), do: take_number(v) == {:ok, ""} or math_function_call?(v)
  defp percentage_value?(v), do: take_number(v) == {:ok, "%"} or math_function_call?(v)

  defp length_value?(v) do
    match?({:ok, unit} when unit in @length_units, take_number(v)) or
      lowercase_function_name(v) == "--spacing" or math_function_call?(v)
  end

  defp fraction_value?(v) do
    with {:ok, rest} <- take_number(v),
         "/" <> rest <- Text.trim_leading_whitespace(rest) do
      take_number(Text.trim_leading_whitespace(rest)) == {:ok, ""}
    else
      _ -> false
    end
  end

  defp vector_value?(v) do
    with {:ok, " " <> rest} <- take_number(v),
         {:ok, " " <> rest} <- take_number(String.trim_leading(rest, " ")) do
      take_number(String.trim_leading(rest, " ")) == {:ok, ""}
    else
      _ -> false
    end
  end

  # Same as matching `[+-]?\d*\.?\d+(?:[eE][+-]?\d+)?` at the start of `v`. We always take the longest
  # number. No suffix we check for starts with a digit or `.`, so a shorter match never helps.
  defp take_number(<<sign, rest::binary>>) when sign in [?+, ?-], do: take_unsigned_number(rest)
  defp take_number(v), do: take_unsigned_number(v)

  defp take_unsigned_number(v) do
    {int, rest} = split_leading_digits(v)

    {frac, rest} =
      with "." <> after_dot <- rest,
           {frac, after_frac} when frac != "" <- split_leading_digits(after_dot) do
        {frac, after_frac}
      else
        _ -> {"", rest}
      end

    if int == "" and frac == "", do: :error, else: {:ok, take_exponent(rest)}
  end

  defp take_exponent(<<e, rest::binary>> = v) when e in [?e, ?E] do
    unsigned = with <<sign, after_sign::binary>> when sign in [?+, ?-] <- rest, do: after_sign

    case split_leading_digits(unsigned) do
      {"", _} -> v
      {_, after_digits} -> after_digits
    end
  end

  defp take_exponent(v), do: v

  defp split_leading_digits(v) do
    size = find_digits_end(v, 0)
    {binary_part(v, 0, size), binary_part(v, size, byte_size(v) - size)}
  end

  defp find_digits_end(v, i) do
    case v do
      <<_::binary-size(^i), c, _::binary>> when c in ?0..?9 -> find_digits_end(v, i + 1)
      _ -> i
    end
  end

  defp lowercase_function_name(v) do
    case :binary.split(v, "(") do
      [name, _] -> String.downcase(name, :ascii)
      [_] -> nil
    end
  end

  defp function_name(v) do
    case :binary.split(v, "(") do
      [name, _] -> name
      [_] -> nil
    end
  end

  defp url_value?(v), do: String.starts_with?(v, "url(") and String.ends_with?(v, ")")

  defp image_value?(v) do
    v
    |> Text.split_top_level(",")
    |> Enum.reduce_while(0, fn part, n ->
      cond do
        String.starts_with?(part, "var(") -> {:cont, n}
        url_value?(part) -> {:cont, n + 1}
        function_name(part) in @gradient_fns -> {:cont, n + 1}
        function_name(part) in @image_fns -> {:cont, n + 1}
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
