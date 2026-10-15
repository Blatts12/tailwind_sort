defmodule TailwindSort.Design do
  @moduledoc """
  Holds everything the sorter needs to know about your Tailwind design system.

  It merges the generated data in `priv/tailwind_data.etf` with whatever your stylesheet adds,
  like theme keys, custom variants and custom utilities.
  """

  alias TailwindSort.DataType
  alias TailwindSort.Design.CustomUtility
  alias TailwindSort.Design.VariantTable
  alias TailwindSort.Stylesheet
  alias TailwindSort.Text.ArbitraryValue

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

  @doc """
  Loads the design for a stylesheet path, or the default theme when the path is nil.
  We cache one design per path and options, and rebuild it when the CSS changes, imports included.

  The only option is `:icon_prefix`. It defaults to `"hero-"`, and `nil` turns icon classes off.
  """
  @spec load_design(Path.t() | nil, keyword()) :: t()
  def load_design(stylesheet \\ nil, opts \\ []) do
    icon_prefix = Keyword.get(opts, :icon_prefix, @default_icon_prefix)
    key = {__MODULE__, stylesheet && Path.expand(stylesheet), icon_prefix}
    css = Stylesheet.read_css_with_imports(stylesheet)

    case :persistent_term.get(key, nil) do
      {^css, design} ->
        design

      _ ->
        design = build_design(Stylesheet.parse_stylesheet(css), icon_prefix: icon_prefix)
        design = %{design | cache_key: {key, :erlang.unique_integer()}}
        :persistent_term.put(key, {css, design})
        design
    end
  end

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
        Map.put_new(acc, DataType.infer_types(ArbitraryValue.decode_arbitrary_value(raw), named_colors), i)
      end)

    {custom_static, custom_functional} =
      CustomUtility.build_custom_utilities(css.utilities, Keyword.get(opts, :icon_prefix), property_index)

    {variants, variant_cmp} = VariantTable.build_variant_table(d, theme, css.variants)

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
      variants: variants,
      variant_cmp: variant_cmp,
      functional_variant_rules: d.functional_variant_rules,
      custom_static: custom_static,
      custom_functional: custom_functional,
      compound_chains: d.compound_chains,
      keywords: MapSet.new(d.keywords),
      ignored_theme_keys: d.ignored_theme_keys,
      custom_variants: MapSet.new(css.variants, &elem(&1, 0))
    }
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
end
