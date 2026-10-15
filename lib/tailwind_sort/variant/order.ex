defmodule TailwindSort.Variant.Order do
  @moduledoc """
  Decides which of two parsed variants sorts first.

  This is a port of `Variants#compare` from `variants.ts` and `compareBreakpoints` from
  `utils/compare-breakpoints.ts`.
  """

  alias TailwindSort.Design
  alias TailwindSort.Variant

  @doc "Port of Variants#compare. The raw string is the identity, because Tailwind caches variants by it."
  @spec compare_variants(Variant.t(), Variant.t(), Design.t()) :: integer()
  def compare_variants(%{raw: r}, %{raw: r}, _d), do: 0

  def compare_variants(%{kind: :arbitrary} = a, %{kind: :arbitrary} = z, _d),
    do: if(a.selector < z.selector, do: -1, else: 1)

  def compare_variants(%{kind: :arbitrary}, _, _d), do: 1
  def compare_variants(_, %{kind: :arbitrary}, _d), do: -1

  def compare_variants(a, z, d) do
    ao = d.variants[a.root].order
    zo = d.variants[z.root].order

    cond do
      ao != zo ->
        ao - zo

      a.kind == :compound and z.kind == :compound ->
        case compare_variants(a.variant, z.variant, d) do
          0 -> compare_modifiers(a.modifier, z.modifier)
          c -> c
        end

      cmp = d.variant_cmp[ao] ->
        compare_breakpoint_variants(a, z, cmp, d)

      a.root != z.root ->
        if a.root < z.root, do: -1, else: 1

      true ->
        compare_values(a.value, z.value)
    end
  end

  defp compare_modifiers(nil, nil), do: 0
  defp compare_modifiers(_, nil), do: 1
  defp compare_modifiers(nil, _), do: -1
  defp compare_modifiers({_, a}, {_, z}), do: if(a < z, do: -1, else: 1)

  defp compare_values(nil, _), do: -1
  defp compare_values(_, nil), do: 1
  defp compare_values({:arbitrary, _, _}, {:named, _}), do: 1
  defp compare_values({:named, _}, {:arbitrary, _, _}), do: -1
  defp compare_values(a, z), do: if(elem(a, 1) < elem(z, 1), do: -1, else: 1)

  defp compare_breakpoint_variants(a, z, {ns, dir}, d) do
    av = resolve_width(a, ns, d)
    zv = resolve_width(z, ns, d)

    cond do
      av == nil -> if dir == :asc, do: -1, else: 1
      zv == nil -> if dir == :asc, do: 1, else: -1
      true -> compare_breakpoints(av, zv, dir)
    end
  end

  defp resolve_width(%{kind: :static, root: root}, :breakpoint, d), do: d.theme["--breakpoint-#{root}"]

  defp resolve_width(%{kind: :functional, modifier: m}, :breakpoint, _d) when m != nil, do: nil
  defp resolve_width(%{kind: :functional, value: nil}, _ns, _d), do: nil

  defp resolve_width(%{kind: :functional, value: value}, ns, d) do
    v =
      case value do
        {:arbitrary, v, _} -> v
        {:named, n} -> d.theme["--#{ns}-#{n}"]
      end

    if v in [nil, ""] or String.contains?(v, "var("), do: nil, else: v
  end

  defp resolve_width(_, _, _), do: nil

  defp compare_breakpoints(a, a, _dir), do: 0

  defp compare_breakpoints(a, z, dir) do
    order =
      case {to_unit_bucket(a), to_unit_bucket(z)} do
        {b, b} -> diff_parsed_ints(a, z, dir)
        {ab, zb} -> if ab < zb, do: -1, else: 1
      end

    if order == :nan, do: if(a < z, do: -1, else: 1), else: order
  end

  defp to_unit_bucket(v) do
    case :binary.match(v, "(") do
      :nomatch -> for <<c <- v>>, c not in ?0..?9 and c != ?., into: "", do: <<c>>
      {i, _} -> binary_part(v, 0, i)
    end
  end

  defp diff_parsed_ints(a, z, dir) do
    with {ai, _} <- parse_int_like_js(a), {zi, _} <- parse_int_like_js(z) do
      if dir == :asc, do: ai - zi, else: zi - ai
    else
      _ -> :nan
    end
  end

  defp parse_int_like_js(v), do: v |> String.trim_leading() |> Integer.parse()
end
