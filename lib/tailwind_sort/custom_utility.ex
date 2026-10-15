defmodule TailwindSort.CustomUtility do
  @moduledoc """
  Handles utilities that your stylesheet adds with `@utility`, plus icon classes like `hero-x-mark`.

  `build_custom_utilities/3` turns them into signatures and value rules when we load the design.
  `custom_utility_accepts?/4` checks those rules against a parsed class when we sort.
  """

  alias TailwindSort.Candidate
  alias TailwindSort.DataType
  alias TailwindSort.Design
  alias TailwindSort.Text

  @type rules :: map() | :icon

  # Declarations that Phoenix's heroicons plugin in assets/vendor/heroicons.js emits, in that order.
  @icon_decls ~w(--icon -webkit-mask mask mask-repeat background-color vertical-align display width height)

  @doc """
  Splits `@utility` blocks into static ones like `content-auto` and functional ones like `tab-*`.
  Returns `{static, functional}`. Static maps a name to its signatures. Functional maps a root to
  `{signature, rules}` pairs, and the icon root goes there too.
  """
  @spec build_custom_utilities([{String.t(), [{String.t(), String.t()}]}], String.t() | nil, map()) ::
          {%{String.t() => [term()]}, %{String.t() => [{term(), rules()}]}}
  def build_custom_utilities(utilities, icon_prefix, property_index) do
    {static, functional} =
      Enum.reduce(utilities, {%{}, %{}}, fn {name, decls}, {static, functional} ->
        sig = compute_decls_signature(decls, property_index)

        if String.ends_with?(name, "-*") do
          entry = {sig, parse_value_rules(decls)}
          {static, Map.update(functional, String.trim_trailing(name, "-*"), [entry], &[entry | &1])}
        else
          {Map.update(static, name, [sig], &[sig | &1]), functional}
        end
      end)

    {static, put_icon_root(functional, icon_prefix, property_index)}
  end

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

  @doc "Checks whether a custom utility's rules accept the parsed value and modifier."
  @spec custom_utility_accepts?(rules(), Candidate.value(), Candidate.modifier(), Design.t()) :: boolean()
  def custom_utility_accepts?(:icon, value, modifier, _d), do: match?({:named, _}, value) and modifier == nil

  def custom_utility_accepts?(_rules, nil, _modifier, _d), do: false

  def custom_utility_accepts?(rules, value, modifier, d),
    do: (modifier == nil or rules.modifier) and rules_accept_value?(value, rules, d)

  defp rules_accept_value?(_value, %{any_value: true}, _d), do: true

  defp rules_accept_value?({:named, v}, rules, d) do
    v in rules.literal or Enum.any?(rules.ns, &Design.theme_has_key?(d, &1, v)) or
      Enum.any?(rules.bare, fn
        "any" -> true
        "integer" -> Text.digits?(v)
        "number" -> Text.quarter_multiple?(v) or Text.digits?(v)
        "percentage" -> Text.percent_value?(v, &Text.digits?/1)
        "ratio" -> false
      end)
  end

  defp rules_accept_value?({:arbitrary, hint, v}, rules, d) do
    types = DataType.infer_types(v, d.named_colors)

    Enum.any?(rules.arbitrary, fn
      "*" -> true
      t -> if hint, do: hint == t, else: types != :var and MapSet.member?(types, t)
    end)
  end
end
