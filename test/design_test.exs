defmodule TailwindSort.DesignTest do
  use ExUnit.Case, async: false

  alias TailwindSort.Design

  @tag :tmp_dir
  test "replaces the cached design when the stylesheet changes", %{tmp_dir: dir} do
    css = Path.join(dir, "app.css")
    File.cp!("test/fixtures/custom.css", css)
    Design.load_design(css)
    count = :persistent_term.info().count

    File.touch!(css, System.os_time(:second) + 60)
    Design.load_design(css)

    assert :persistent_term.info().count == count
  end

  @tag :tmp_dir
  test "sorts with the new stylesheet after it changes", %{tmp_dir: dir} do
    css = Path.join(dir, "app.css")
    File.write!(css, ~s(@import "tailwindcss";))
    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "content-auto p-4"

    File.write!(css, ~s(@import "tailwindcss";\n@utility content-auto { content-visibility: auto; }))
    File.touch!(css, System.os_time(:second) + 60)

    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "p-4 content-auto"
  end
end
