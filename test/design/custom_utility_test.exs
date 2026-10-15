defmodule TailwindSort.Design.CustomUtilityTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Design.CustomUtility

  setup_all do
    %{d: Design.load_design()}
  end

  describe "build_custom_utilities/3" do
    test "splits static utilities from functional ones", %{d: d} do
      utilities = [
        {"content-auto", [{"content-visibility", "auto"}]},
        {"tab-*", [{"tab-size", "--value(integer)"}]}
      ]

      {static, functional} = CustomUtility.build_custom_utilities(utilities, nil, d.property_index)

      assert Map.keys(static) == ["content-auto"]
      assert Map.keys(functional) == ["tab"]
    end

    test "adds the icon root for the icon prefix", %{d: d} do
      {_, functional} = CustomUtility.build_custom_utilities([], "lucide-", d.property_index)
      assert [{_, :icon}] = functional["lucide"]
    end

    test "adds no icon root without a prefix", %{d: d} do
      assert CustomUtility.build_custom_utilities([], nil, d.property_index) == {%{}, %{}}
    end
  end

  describe "custom_utility_accepts?/4" do
    setup %{d: d} do
      {_, %{"tab" => [{_, rules}]}} =
        CustomUtility.build_custom_utilities([{"tab-*", [{"tab-size", "--value(integer)"}]}], nil, d.property_index)

      %{rules: rules}
    end

    test "accepts a value that matches the --value() types", %{d: d, rules: rules} do
      assert CustomUtility.custom_utility_accepts?(rules, {:named, "4"}, nil, d)
      refute CustomUtility.custom_utility_accepts?(rules, {:named, "wide"}, nil, d)
    end

    test "rejects a modifier when the utility has no --modifier()", %{d: d, rules: rules} do
      refute CustomUtility.custom_utility_accepts?(rules, {:named, "4"}, {:named, "50"}, d)
    end

    test "accepts any named icon without a modifier", %{d: d} do
      assert CustomUtility.custom_utility_accepts?(:icon, {:named, "x-mark"}, nil, d)
      refute CustomUtility.custom_utility_accepts?(:icon, {:named, "x-mark"}, {:named, "50"}, d)
      refute CustomUtility.custom_utility_accepts?(:icon, {:arbitrary, nil, "x"}, nil, d)
    end
  end
end
