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

    assert css.variants == [
             {"dark", ["&:where(.dark, .dark *)"]},
             {"pointer", ["@media (pointer: fine)"]}
           ]

    assert css.utilities == [{"tab-*", [{"tab-size", "--value(integer)"}]}]
  end

  describe "read_css_with_imports/1" do
    test "gives empty CSS without a path" do
      assert Stylesheet.read_css_with_imports(nil) == ""
    end

    @tag :tmp_dir
    test "inlines local imports and leaves package imports alone", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "app.css"), ~s(@import "tailwindcss";\n@import "./theme.css";))
      File.write!(Path.join(dir, "theme.css"), "@theme { --color-brand: #123; }")

      assert Stylesheet.read_css_with_imports(Path.join(dir, "app.css")) ==
               ~s(@import "tailwindcss";\n@theme { --color-brand: #123; })
    end

    @tag :tmp_dir
    test "reads each file once when imports loop", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.css"), ~s(a{}@import "./b.css";))
      File.write!(Path.join(dir, "b.css"), ~s(b{}@import "./a.css";))

      assert Stylesheet.read_css_with_imports(Path.join(dir, "a.css")) == "a{}b{}"
    end
  end
end
