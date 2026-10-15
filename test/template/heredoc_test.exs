defmodule TailwindSort.Template.HeredocTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Template.Heredoc

  setup do
    src = ~s("""\n  p-4 flex\n  hover:\\\n  mt-2\n  """)
    lines = Heredoc.split_heredoc_lines(src, [{:static, 3, byte_size(src) - 3}])
    %{text: for(line <- lines, do: for({:static, s, e} <- line, do: binary_part(src, s, e - s)))}
  end

  describe "split_heredoc_lines/2" do
    test "drops the opening line and each line's indent", %{text: [first | _]} do
      assert first == ["p-4 flex"]
    end

    test "keeps lines joined by a trailing backslash together", %{text: [_, second | _]} do
      assert second == ["hover:\\\n  mt-2"]
    end

    test "leaves the closing line empty", %{text: text} do
      assert List.last(text) == [""]
    end
  end
end
