defmodule TailwindSort.DataType.Number do
  @moduledoc """
  Reads a CSS number like `12`, `-.5` or `1e3` from the start of a value, so the type checks in
  `TailwindSort.DataType` can look at the unit that follows.
  """

  @doc """
  Same as matching `[+-]?\\d*\\.?\\d+(?:[eE][+-]?\\d+)?` at the start of `v`. Returns
  `{:ok, rest}` with what follows the number, or `:error` when `v` doesn't start with one.

  We always take the longest number. No suffix we check for starts with a digit or `.`, so a
  shorter match never helps.
  """
  @spec take_number(String.t()) :: {:ok, String.t()} | :error
  def take_number(<<sign, rest::binary>>) when sign in [?+, ?-], do: take_unsigned_number(rest)
  def take_number(v), do: take_unsigned_number(v)

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
end
