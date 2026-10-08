defmodule TailwindSort.Sorter do
  @moduledoc """
  Puts a list of classes in the order Tailwind would emit their CSS.

  This is a port of `getClassOrder` from `sort.ts` and `compile.ts`, plus the list handling of
  `prettier-plugin-tailwindcss`. Unknown classes go first, `...` goes last, and known
  duplicates go away.
  """

  import Bitwise

  alias TailwindSort.Candidate
  alias TailwindSort.Design
  alias TailwindSort.Text
  alias TailwindSort.Utility
  alias TailwindSort.Variant

  @max_cached_classes 20_000

  @type sort_key :: {non_neg_integer(), Utility.signature(), String.t()}

  @doc "Builds a sort key for each class. A nil key marks a class Tailwind doesn't generate."
  @spec build_class_order(classes :: [String.t()], Design.t()) :: %{String.t() => sort_key() | nil}
  def build_class_order(classes, d) do
    resolved = resolve_classes(Enum.uniq(classes), d)
    ranks = rank_variants(resolved, d)

    Map.new(resolved, fn
      {class, nil} ->
        {class, nil}

      {class, {variants, sig}} ->
        {class, {Enum.reduce(variants, 0, &bor(&2, 1 <<< Map.fetch!(ranks, &1.raw))), sig, class}}
    end)
  end

  defp resolve_classes(classes, %Design{cache_key: nil} = d), do: resolve_new_classes(classes, d)

  # Mix formats each file in its own task, and a file repeats the same classes in many attributes.
  # So we keep resolved classes in the process dictionary. Language servers reuse one process for
  # many files, which is why the cache has a size cap.
  defp resolve_classes(classes, d) do
    cache =
      case Process.get(__MODULE__) do
        {key, cache} when key == d.cache_key and map_size(cache) < @max_cached_classes -> cache
        _ -> %{}
      end

    case Enum.reject(classes, &is_map_key(cache, &1)) do
      [] ->
        Map.take(cache, classes)

      missing ->
        cache = Map.merge(cache, resolve_new_classes(missing, d))
        Process.put(__MODULE__, {d.cache_key, cache})
        Map.take(cache, classes)
    end
  end

  # Many classes share a variant like `hover`, so we check each variant once per batch.
  defp resolve_new_classes(classes, d) do
    parsed = Map.new(classes, &{&1, parse_class(&1, d)})

    for_result = for({_, {variants, _}} <- parsed, v <- variants, do: v)

    produces_css =
      for_result
      |> Enum.uniq_by(& &1.raw)
      |> Map.new(&{&1.raw, Variant.produces_css?(&1, d)})

    Map.new(parsed, fn
      {class, {variants, _} = resolved} ->
        {class, if(Enum.all?(variants, &Map.fetch!(produces_css, &1.raw)), do: resolved)}

      unknown ->
        unknown
    end)
  end

  defp parse_class(class, d) do
    with {variants, parses} <- Candidate.parse_candidate(class, d),
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
    for_result = for({_, {vs, _}} <- resolved, v <- vs, do: v)

    sorted =
      for_result
      |> Enum.uniq_by(& &1.raw)
      |> Enum.sort(&(Variant.compare_variants(&1, &2, d) <= 0))

    {ranks, _, _} =
      Enum.reduce(sorted, {%{}, nil, 0}, fn v, {acc, prev, i} ->
        i = if prev != nil and Variant.compare_variants(prev, v, d) != 0, do: i + 1, else: i
        {Map.put(acc, v.raw, i), v, i}
      end)

    ranks
  end

  @spec compare_sort_keys(sort_key(), sort_key()) :: integer()
  def compare_sort_keys({ab, as, an}, {zb, zs, zn}) do
    cond do
      ab != zb -> ab - zb
      (c = Utility.compare_signatures(as, zs)) != 0 -> c
      true -> Text.compare_alnum(an, zn)
    end
  end

  @doc "Sorts a list of classes the way prettier-plugin-tailwindcss does. Returns `{sorted, removed_count}`."
  @spec sort_class_list(classes :: [String.t()], Design.t(), keyword()) :: {[String.t()], non_neg_integer()}
  def sort_class_list(classes, d, opts \\ []) do
    order = build_class_order(classes, d)
    {ellipsis, rest} = Enum.split_with(classes, &(&1 in ["...", "…"]))
    {unknown, known} = Enum.split_with(rest, &is_nil(Map.fetch!(order, &1)))
    known = if Keyword.get(opts, :remove_duplicates, true), do: Enum.uniq(known), else: known

    # Each key ends with its class, so we sort the keys and read the classes back out.
    sorted_known =
      known
      |> Enum.map(&Map.fetch!(order, &1))
      |> Enum.sort(&(compare_sort_keys(&1, &2) <= 0))
      |> Enum.map(&elem(&1, 2))

    {unknown ++ sorted_known ++ ellipsis, length(rest) - length(unknown) - length(known)}
  end

  @doc """
  Sorts a whitespace separated class string. This ports `sortClasses` from prettier-plugin-tailwindcss.

  `:ignore_first` and `:ignore_last` keep the first or last token in place, because it's glued to
  an interpolation. `:collapse_start` and `:collapse_end` trim leading or trailing whitespace.
  """
  @spec sort_class_string(classes :: String.t(), Design.t(), keyword()) :: String.t()
  def sort_class_string(str, d, opts \\ []) do
    {classes, gaps} = split_classes(str)

    {prefix, classes, gaps} =
      if opts[:ignore_first] && classes != [],
        do: {hd(classes) <> gap_space(gaps), tl(classes), max(gaps - 1, 0)},
        else: {"", classes, gaps}

    {suffix, classes, gaps} =
      if opts[:ignore_last] && classes != [],
        do: {gap_space(gaps) <> List.last(classes), Enum.drop(classes, -1), max(gaps - 1, 0)},
        else: {"", classes, gaps}

    {sorted, removed} = sort_class_list(classes, d, opts)
    trailing = if sorted != [] and gaps - removed >= length(sorted), do: " ", else: ""

    result =
      (Enum.join(sorted, " ") <> trailing)
      |> replace_leading_whitespace(if(Keyword.get(opts, :collapse_start, true), do: "", else: " "))
      |> replace_trailing_whitespace(if(Keyword.get(opts, :collapse_end, true), do: "", else: " "))

    replace_trailing_whitespace(prefix, " ") <> result <> replace_leading_whitespace(suffix, " ")
  end

  # Mirrors the split in prettier-plugin-tailwindcss. Leading whitespace leaves an empty first class,
  # which is unknown and so stays in front. `gaps` counts the whitespace runs, and each run becomes one space.
  defp split_classes(""), do: {[], 0}

  defp split_classes(str) do
    parts = :binary.split(str, [" ", "\t", "\r", "\f", "\n"], [:global])
    classes = Enum.reject(parts, &(&1 == ""))
    lead = if hd(parts) == "", do: 1, else: 0
    trail = if List.last(parts) == "", do: 1, else: 0

    case classes do
      [] -> {[""], 1}
      _ when lead == 1 -> {["" | classes], length(classes) + trail}
      _ -> {classes, length(classes) - 1 + trail}
    end
  end

  defp gap_space(0), do: ""
  defp gap_space(_), do: " "

  defp replace_leading_whitespace(str, replacement) do
    case Text.trim_leading_whitespace(str) do
      ^str -> str
      trimmed -> replacement <> trimmed
    end
  end

  defp replace_trailing_whitespace(str, replacement) do
    case Text.trim_trailing_whitespace(str) do
      ^str -> str
      trimmed -> trimmed <> replacement
    end
  end
end
