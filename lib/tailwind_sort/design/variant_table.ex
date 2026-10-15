defmodule TailwindSort.Design.VariantTable do
  @moduledoc """
  Builds the variant table of a design: Tailwind's core variants, one variant per theme
  breakpoint, and the custom variants from your stylesheet.

  Each entry holds the variant's kind, its sort order, and the compound bits that say which
  compound variants like `group-*` or `not-*` may wrap it.
  """

  @doc """
  Returns `{variants, comparators}`. `variants` maps a name to its entry. `comparators` maps the
  sort order of `min`, `max`, `@min` and `@max` to how their values compare.
  """
  @spec build_variant_table(data :: map(), theme :: map(), custom :: [{String.t(), [String.t()]}]) ::
          {%{String.t() => map()}, %{non_neg_integer() => {:breakpoint | :container, :asc | :desc}}}
  def build_variant_table(data, theme, custom) do
    variants =
      data.variants
      |> Map.new(fn {name, kind, order, compounds, cw, _cmp} ->
        {name, %{kind: kind, order: order, compounds: compounds, compounds_with: cw}}
      end)
      |> Map.merge(build_breakpoint_variants(theme, data.breakpoint_order))
      |> add_custom_variants(custom)

    {variants, build_variant_comparators(data.variants)}
  end

  defp build_breakpoint_variants(theme, order) do
    for {"--breakpoint-" <> name, _} <- theme, not String.contains?(name, "--"), into: %{} do
      {name, %{kind: :static, order: order, compounds: 1, compounds_with: 0}}
    end
  end

  defp add_custom_variants(variants, custom) do
    max_order = variants |> Map.values() |> Enum.map(& &1.order) |> Enum.max()

    {variants, _} =
      Enum.reduce(custom, {variants, max_order}, fn {name, selectors}, {acc, last} ->
        compounds = compute_selector_compounds(selectors)

        case acc do
          %{^name => existing} ->
            {Map.put(acc, name, %{existing | kind: :static, compounds: compounds}), last}

          _ ->
            {Map.put(acc, name, %{kind: :static, order: last + 1, compounds: compounds, compounds_with: 0}), last + 1}
        end
      end)

    variants
  end

  defp build_variant_comparators(core_variants) do
    Enum.reduce(core_variants, %{}, fn
      {"max", _, o, _, _, true}, acc -> Map.put(acc, o, {:breakpoint, :desc})
      {"min", _, o, _, _, true}, acc -> Map.put(acc, o, {:breakpoint, :asc})
      {"@max", _, o, _, _, true}, acc -> Map.put(acc, o, {:container, :desc})
      {"@min", _, o, _, _, true}, acc -> Map.put(acc, o, {:container, :asc})
      _, acc -> acc
    end)
  end

  @doc "Port of compoundsForSelectors. Bit 1 stands for at-rules and bit 2 for style rules. 0 means never."
  @spec compute_selector_compounds(selectors :: [String.t()]) :: 0..3
  def compute_selector_compounds(selectors) do
    Enum.reduce_while(selectors, 0, fn sel, acc ->
      cond do
        String.starts_with?(sel, "@") ->
          if Enum.any?(~w(@media @supports @container), &String.starts_with?(sel, &1)),
            do: {:cont, Bitwise.bor(acc, 1)},
            else: {:halt, 0}

        String.contains?(sel, "::") ->
          {:halt, 0}

        true ->
          {:cont, Bitwise.bor(acc, 2)}
      end
    end)
  end
end
