defmodule TailwindSort.Sorter do
  @moduledoc """
  Puts a list of classes in the order Tailwind would emit their CSS.

  This is a port of `getClassOrder` from `sort.ts` and `compile.ts`, plus the list handling of
  `prettier-plugin-tailwindcss`. Unknown classes go first, `...` goes last, and known
  duplicates go away. `TailwindSort.Sorter.ClassString` sorts whole class strings.
  """

  import Bitwise

  alias TailwindSort.Candidate
  alias TailwindSort.Design
  alias TailwindSort.Text
  alias TailwindSort.Utility
  alias TailwindSort.Variant
  alias TailwindSort.Variant.Order

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

    produces_css =
      parsed
      |> list_used_variants()
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
         sig when sig != nil <- parses |> Enum.map(&Utility.compute_signature(&1, d)) |> Utility.pick_min_signature() do
      {variants, sig}
    else
      _ -> nil
    end
  end

  # Port of getVariantOrder. We sort every variant in use, and variants that compare equal share a bit.
  defp rank_variants(resolved, d) do
    sorted =
      resolved
      |> list_used_variants()
      |> Enum.sort(&(Order.compare_variants(&1, &2, d) <= 0))

    {ranks, _, _} =
      Enum.reduce(sorted, {%{}, nil, 0}, fn v, {acc, prev, i} ->
        i = if prev != nil and Order.compare_variants(prev, v, d) != 0, do: i + 1, else: i
        {Map.put(acc, v.raw, i), v, i}
      end)

    ranks
  end

  defp list_used_variants(classes) do
    for_result = for({_, {variants, _}} <- classes, v <- variants, do: v)
    Enum.uniq_by(for_result, & &1.raw)
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
end
