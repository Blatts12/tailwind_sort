defmodule TailwindSort.Sorter do
  @moduledoc false
  # Port of getClassOrder from sort.ts and compile.ts, plus the list handling of
  # prettier-plugin-tailwindcss. Unknown classes go first, `...` goes last, and known duplicates go away.

  import Bitwise
  alias TailwindSort.{Candidate, Text, Utility, Variant}

  @doc "Builds a sort key for each class. A nil key marks a class Tailwind doesn't generate."
  def build_class_order(classes, d) do
    resolved = classes |> Enum.uniq() |> Map.new(&{&1, resolve_class(&1, d)})
    ranks = rank_variants(resolved, d)

    Map.new(resolved, fn
      {class, nil} -> {class, nil}
      {class, {variants, sig}} -> {class, {Enum.reduce(variants, 0, &bor(&2, 1 <<< ranks[&1.raw])), sig, class}}
    end)
  end

  defp resolve_class(class, d) do
    with {variants, parses} <- Candidate.parse_candidate(class, d),
         true <- Enum.all?(variants, &Variant.produces_css?(&1, d)),
         sig when sig != nil <- pick_best_signature(parses, d) do
      {variants, sig}
    else
      _ -> nil
    end
  end

  defp pick_best_signature(parses, d) do
    parses
    |> Enum.map(&Utility.compute_signature(&1, d))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn a, z -> Utility.compare_signatures(a, z) <= 0 end, fn -> nil end)
  end

  # Port of getVariantOrder. We sort every variant in use, and variants that compare equal share a bit.
  defp rank_variants(resolved, d) do
    sorted =
      for({_, {vs, _}} <- resolved, v <- vs, do: v)
      |> Enum.uniq_by(& &1.raw)
      |> Enum.sort(&(Variant.compare_variants(&1, &2, d) <= 0))

    {ranks, _, _} =
      Enum.reduce(sorted, {%{}, nil, 0}, fn v, {acc, prev, i} ->
        i = if prev != nil and Variant.compare_variants(prev, v, d) != 0, do: i + 1, else: i
        {Map.put(acc, v.raw, i), v, i}
      end)

    ranks
  end

  def compare_sort_keys({ab, as, an}, {zb, zs, zn}) do
    cond do
      ab != zb -> ab - zb
      (c = Utility.compare_signatures(as, zs)) != 0 -> c
      true -> Text.compare_alnum(an, zn)
    end
  end

  @doc "Sorts a list of classes the way prettier-plugin-tailwindcss does. Returns `{sorted, removed_count}`."
  def sort_class_list(classes, d, opts \\ []) do
    order = build_class_order(classes, d)
    {ellipsis, rest} = Enum.split_with(classes, &(&1 in ["...", "…"]))
    {unknown, known} = Enum.split_with(rest, &is_nil(order[&1]))
    known = Enum.sort(known, &(compare_sort_keys(order[&1], order[&2]) <= 0))
    sorted = unknown ++ known ++ ellipsis

    if Keyword.get(opts, :remove_duplicates, true) do
      {kept, _} =
        Enum.reduce(sorted, {[], MapSet.new()}, fn c, {acc, seen} ->
          cond do
            MapSet.member?(seen, c) -> {acc, seen}
            order[c] == nil -> {[c | acc], seen}
            true -> {[c | acc], MapSet.put(seen, c)}
          end
        end)

      {Enum.reverse(kept), length(sorted) - length(kept)}
    else
      {sorted, 0}
    end
  end

  @doc """
  Sorts a whitespace separated class string. This ports `sortClasses` from prettier-plugin-tailwindcss.

  `:ignore_first` and `:ignore_last` keep the first or last token in place, because it's glued to
  an interpolation. `:collapse_start` and `:collapse_end` trim leading or trailing whitespace.
  """
  def sort_class_string(str, d, opts \\ []) do
    parts = Regex.split(~r/[\t\r\f\n ]+/, str, include_captures: true)
    classes = parts |> Enum.take_every(2)
    whitespace = parts |> Enum.drop(1) |> Enum.take_every(2) |> Enum.map(fn _ -> " " end)
    classes = if List.last(classes) == "", do: Enum.drop(classes, -1), else: classes

    {prefix, classes, whitespace} =
      if opts[:ignore_first] && classes != [],
        do: {hd(classes) <> (List.first(whitespace) || ""), tl(classes), Enum.drop(whitespace, 1)},
        else: {"", classes, whitespace}

    {suffix, classes, whitespace} =
      if opts[:ignore_last] && classes != [],
        do: {(List.last(whitespace) || "") <> List.last(classes), Enum.drop(classes, -1), Enum.drop(whitespace, -1)},
        else: {"", classes, whitespace}

    {sorted, removed} = sort_class_list(classes, d, opts)
    whitespace = Enum.drop(whitespace, removed)

    result =
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> c <> (Enum.at(whitespace, i) || "") end)
      |> Enum.join()
      |> then(&Regex.replace(~r/^\s+/, &1, if(Keyword.get(opts, :collapse_start, true), do: "", else: " ")))
      |> then(&Regex.replace(~r/\s+$/, &1, if(Keyword.get(opts, :collapse_end, true), do: "", else: " ")))

    Regex.replace(~r/\s+$/, prefix, " ") <> result <> Regex.replace(~r/^\s+/, suffix, " ")
  end
end
