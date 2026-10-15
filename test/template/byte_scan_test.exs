defmodule TailwindSort.Template.ByteScanTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Template.ByteScan

  describe "skip_past/3" do
    test "returns the offset after the pattern" do
      assert ByteScan.skip_past("<!-- x --> y", 0, "-->") == 10
    end

    test "returns the end of the source when the pattern is missing" do
      assert ByteScan.skip_past("<!-- x", 0, "-->") == 6
    end
  end

  test "peek_bytes/3 returns fewer bytes near the end and nothing past it" do
    assert ByteScan.peek_bytes("abc", 1, 5) == "bc"
    assert ByteScan.peek_bytes("abc", 3, 1) == ""
  end

  test "skip_ws/2 skips spaces, tabs and newlines" do
    assert ByteScan.skip_ws("a \t\r\n b", 1) == 6
  end

  test "skip_ws_back/2 stops at a newline" do
    assert ByteScan.skip_ws_back("a\n  b", 4) == 2
  end

  test "take_bytes_while/3 returns the bytes taken and the offset after them" do
    assert ByteScan.take_bytes_while("div class", 0, &(&1 != ?\s)) == {"div", 3}
  end
end
