defmodule TailwindSort.Text.ArbitraryValueTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Text.ArbitraryValue

  describe "valid_arbitrary_value?/1" do
    test "accepts balanced brackets" do
      assert ArbitraryValue.valid_arbitrary_value?("calc(1px+2px)")
    end

    test "rejects a closing bracket without an opening one" do
      refute ArbitraryValue.valid_arbitrary_value?("a)")
    end

    test "rejects a top-level semicolon but not one inside quotes" do
      refute ArbitraryValue.valid_arbitrary_value?("a;b")
      assert ArbitraryValue.valid_arbitrary_value?("'a;b'")
    end
  end

  describe "decode_arbitrary_value/1" do
    test "turns underscores into spaces" do
      assert ArbitraryValue.decode_arbitrary_value("calc(100%_-_1rem)") == "calc(100% - 1rem)"
    end

    test "keeps an escaped underscore" do
      assert ArbitraryValue.decode_arbitrary_value(~S(a\_b)) == "a_b"
    end

    test "leaves url() contents as written" do
      assert ArbitraryValue.decode_arbitrary_value("url(a_b.png)") == "url(a_b.png)"
    end

    test "keeps underscores in the variable name of var() but not in its fallback" do
      assert ArbitraryValue.decode_arbitrary_value("var(--my_var,1px_2px)") == "var(--my_var,1px 2px)"
    end
  end

  describe "decode_valid_arbitrary_value/1" do
    test "returns nil for a value that decodes to blank" do
      assert ArbitraryValue.decode_valid_arbitrary_value("_") == nil
    end

    test "returns nil for an invalid value" do
      assert ArbitraryValue.decode_valid_arbitrary_value("a;b") == nil
    end

    test "returns the decoded value otherwise" do
      assert ArbitraryValue.decode_valid_arbitrary_value("1px_2px") == "1px 2px"
    end
  end
end
