defmodule TailwindSort.StylesheetTest do
  use ExUnit.Case, async: true
  alias TailwindSort.Stylesheet

  test "reads theme, resets, custom variants, utilities and prefix" do
    css =
      Stylesheet.parse_stylesheet(~S"""
      @import "tailwindcss" prefix(tw);
      /* @theme { --color-ignored: red; } */
      @theme inline {
        --color-*: initial;
        --color-brand\.light: #fff;
      }
      @custom-variant dark (&:where(.dark, .dark *));
      @custom-variant pointer { @media (pointer: fine) { @slot; } }
      @utility tab-* { tab-size: --value(integer); }
      """)

    assert css.prefix == "tw"
    assert css.theme == [{:reset, "--color-"}, {:set, "--color-brand.light", "#fff"}]
    assert css.variants == [{"dark", ["&:where(.dark, .dark *)"]}, {"pointer", ["@media (pointer: fine)"]}]
    assert css.utilities == [{"tab-*", [{"tab-size", "--value(integer)"}]}]
  end
end
