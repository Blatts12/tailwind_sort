defmodule TailwindSort.Design do
  # Runtime view of a Tailwind design system. It merges the generated data in
  # priv/tailwind_data.etf with whatever your stylesheet adds.
  @moduledoc false

  alias TailwindSort.DataType
  alias TailwindSort.Stylesheet
  alias TailwindSort.Text

  defstruct [
    :version,
    :prefix,
    :theme,
    :property_index,
    :named_colors,
    :static,
    :functional_roots,
    :exact,
    :exact_modifiers,
    :functional,
    :ns_priority,
    :modifiers,
    :modifier_tables,
    :corpus_by_types,
    :hints,
    :variants,
    :variant_cmp,
    :functional_variant_rules,
    :custom_static,
    :custom_functional,
    :compound_chains,
    :custom_variants,
    :keywords,
    :ignored_theme_keys,
    :cache_key
  ]

  @type t :: %__MODULE__{}

  @data_key {__MODULE__, :data}

  @default_icon_prefix "hero-"

  # Declarations that Phoenix's heroicons plugin in assets/vendor/heroicons.js emits, in that order.
  @icon_decls ~w(--icon -webkit-mask mask mask-repeat background-color vertical-align display width height)

  @doc """
  Loads the design for a stylesheet path, or the default theme when the path is nil.
  We cache one design per path and options, and rebuild it when the file's mtime changes.

  The only option is `:icon_prefix`. It defaults to `"hero-"`, and `nil` turns icon classes off.
  """
  @spec load_design(Path.t() | nil, keyword()) :: t()
  def load_design(stylesheet \\ nil, opts \\ []) do
    icon_prefix = Keyword.get(opts, :icon_prefix, @default_icon_prefix)
    key = {__MODULE__, stylesheet && Path.expand(stylesheet), icon_prefix}
    mtime = read_mtime(stylesheet)

    case :persistent_term.get(key, nil) do
      {^mtime, design} ->
        design

      _ ->
        design = build_design(Stylesheet.read_stylesheet(stylesheet), icon_prefix: icon_prefix)
        design = %{design | cache_key: {key, mtime}}
        :persistent_term.put(key, {mtime, design})
        design
    end
  end

  defp read_mtime(nil), do: nil
  defp read_mtime(path), do: File.stat!(path, time: :posix).mtime

  @spec load_tailwind_data() :: map()
  def load_tailwind_data do
    case :persistent_term.get(@data_key, nil) do
      nil ->
        data =
          :tailwind_sort
          |> :code.priv_dir()
          |> Path.join("tailwind_data.etf")
          |> File.read!()
          |> :erlang.binary_to_term()

        :persistent_term.put(@data_key, data)
        data

      data ->
        data
    end
  end

  @doc false
  @spec build_design(Stylesheet.t(), keyword()) :: t()
  def build_design(%Stylesheet{} = css, opts \\ []) do
    d = load_tailwind_data()
    named_colors = MapSet.new(d.named_colors)
    theme = merge_theme(Map.new(d.theme), css.theme, d.ignored_theme_keys)
    property_index = d.property_order |> Enum.with_index() |> Map.new()

    corpus_by_types =
      d.corpus
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {raw, i}, acc ->
        Map.put_new(acc, DataType.infer_types(Text.decode_arbitrary_value(raw), named_colors), i)
      end)

    {custom_static, custom_functional} = split_custom_utilities(css.utilities, property_index)

    custom_functional =
      put_icon_root(custom_functional, Keyword.get(opts, :icon_prefix), property_index)

    put_variants(
      %__MODULE__{
        version: d.version,
        prefix: css.prefix,
        theme: theme,
        property_index: property_index,
        named_colors: named_colors,
        static: MapSet.new(d.static_utilities ++ Map.keys(custom_static)),
        functional_roots: MapSet.new(d.functional_roots ++ Map.keys(custom_functional)),
        exact: d.exact,
        exact_modifiers: d.exact_modifiers,
        functional: d.functional,
        ns_priority: d.ns_priority,
        modifiers: d.modifiers,
        modifier_tables: d.modifier_tables,
        corpus_by_types: corpus_by_types,
        hints: MapSet.new(d.hints),
        functional_variant_rules: d.functional_variant_rules,
        custom_static: custom_static,
        custom_functional: custom_functional,
        compound_chains: d.compound_chains,
        keywords: MapSet.new(d.keywords),
        ignored_theme_keys: d.ignored_theme_keys,
        custom_variants: MapSet.new(css.variants, &elem(&1, 0))
      },
      d,
      css.variants
    )
  end

  # `--ns-*: initial` clears a namespace, as in Theme#clearNamespace. Keys owned by a more
  # specific namespace survive, so `--text-*: initial` keeps `--text-shadow-*`.
  defp merge_theme(theme, ops, ignored) do
    Enum.reduce(ops, theme, fn
      {:reset, "--"}, _ ->
        %{}

      {:reset, prefix}, acc ->
        keep = Map.get(ignored, String.trim_trailing(prefix, "-"), [])

        Map.reject(acc, fn {k, _} ->
          String.starts_with?(k, prefix) and not Enum.any?(keep, &String.starts_with?(k, &1))
        end)

      {:set, k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  @doc "Checks whether the theme has `value` in namespace `ns`. Keys in Tailwind's ignoredThemeKeyMap don't count."
  @spec theme_has_key?(t(), namespace :: String.t(), value :: String.t()) :: boolean()
  def theme_has_key?(%__MODULE__{theme: theme, ignored_theme_keys: ignored}, ns, value) do
    key = "#{ns}-#{value}"

    Map.has_key?(theme, key) and
      not Enum.any?(Map.get(ignored, ns, []), &(key == &1 or String.starts_with?(key, &1 <> "-")))
  end

  defp put_variants(design, d, custom) do
    core =
      Map.new(d.variants, fn {name, kind, order, compounds, cw, _cmp} ->
        {name, %{kind: kind, order: order, compounds: compounds, compounds_with: cw}}
      end)

    breakpoints =
      for {"--breakpoint-" <> name, _} <- design.theme,
          not String.contains?(name, "--"),
          into: %{} do
        {name, %{kind: :static, order: d.breakpoint_order, compounds: 1, compounds_with: 0}}
      end

    variants = Map.merge(core, breakpoints)
    max_order = variants |> Map.values() |> Enum.map(& &1.order) |> Enum.max()

    {variants, _} =
      Enum.reduce(custom, {variants, max_order}, fn {name, selectors}, {acc, last} ->
        compounds = compute_selector_compounds(selectors)

        case acc do
          %{^name => existing} ->
            {Map.put(acc, name, %{existing | kind: :static, compounds: compounds}), last}

          _ ->
            {Map.put(acc, name, %{
               kind: :static,
               order: last + 1,
               compounds: compounds,
               compounds_with: 0
             }), last + 1}
        end
      end)

    cmp =
      Enum.reduce(d.variants, %{}, fn
        {"max", _, o, _, _, true}, acc -> Map.put(acc, o, {:breakpoint, :desc})
        {"min", _, o, _, _, true}, acc -> Map.put(acc, o, {:breakpoint, :asc})
        {"@max", _, o, _, _, true}, acc -> Map.put(acc, o, {:container, :desc})
        {"@min", _, o, _, _, true}, acc -> Map.put(acc, o, {:container, :asc})
        _, acc -> acc
      end)

    %{design | variants: variants, variant_cmp: cmp}
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

  defp split_custom_utilities(utilities, property_index) do
    Enum.reduce(utilities, {%{}, %{}}, fn {name, decls}, {static, functional} ->
      sig = compute_decls_signature(decls, property_index)

      if String.ends_with?(name, "-*") do
        entry = {sig, parse_value_rules(decls)}
        {static, Map.update(functional, String.trim_trailing(name, "-*"), [entry], &[entry | &1])}
      else
        {Map.update(static, name, [sig], &[sig | &1]), functional}
      end
    end)
  end

  # Works out what `--value(...)` and `--modifier(...)` accept in a functional @utility.
  defp parse_value_rules(decls) do
    body = Enum.map_join(decls, ";", &elem(&1, 1))

    args =
      ~r/--value\(([^)]*)\)/
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.flat_map(fn [a] -> a |> String.split(",") |> Enum.map(&String.trim/1) end)

    %{
      any_value: args == [],
      modifier: String.contains?(body, "--modifier("),
      ns: for("--" <> _ = a <- args, String.ends_with?(a, "-*"), do: String.trim_trailing(a, "-*")),
      bare: for(a <- args, a in ~w(integer number percentage ratio any), do: a),
      literal: for(<<q, _::binary>> = a <- args, q in [?", ?'], do: String.slice(a, 1..-2//1)),
      arbitrary: for("[" <> _ = a <- args, do: String.slice(a, 1..-2//1))
    }
  end

  # Icon classes like `<prefix><name>` behave like Phoenix's heroicons plugin. The `hero` root is
  # functional, accepts any named value and takes no modifier. We don't check names against the
  # icon set, so a typo sorts like a real icon instead of moving to the front.
  defp put_icon_root(functional, prefix, _index) when prefix in [nil, false, ""], do: functional

  defp put_icon_root(functional, prefix, index) when is_binary(prefix) do
    root = String.trim_trailing(prefix, "-")
    sig = compute_decls_signature(Enum.map(@icon_decls, &{&1, ""}), index)
    Map.update(functional, root, [{sig, :icon}], &[{sig, :icon} | &1])
  end

  # Mirrors getPropertySort for declarations collected in breadth first order.
  defp compute_decls_signature(decls, index) do
    {order, _} =
      Enum.reduce(decls, {MapSet.new(), false}, fn
        _, {set, true} ->
          {set, true}

        {"--tw-sort", v}, {set, false} when is_map_key(index, v) ->
          {MapSet.put(set, index[v]), true}

        {p, _}, {set, false} ->
          {if(i = index[p], do: MapSet.put(set, i), else: set), false}
      end)

    {order |> MapSet.to_list() |> Enum.sort(), length(decls)}
  end
end
