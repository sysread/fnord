defmodule AI.Tools.File.Edit.WhitespaceFitterTest do
  use Fnord.TestCase

  alias AI.Tools.File.Edit.WhitespaceFitter

  describe "infer_indent_style/1" do
    test "defaults to 2 spaces when no indentation is present" do
      style = WhitespaceFitter.infer_indent_style(["foo()", "bar()"])
      assert %{type: :spaces, width: 2} = style
    end

    test "detects tab indentation when only tabs are used" do
      style = WhitespaceFitter.infer_indent_style(["\tfoo()", "\t\tbar()"])
      assert %{type: :tabs, width: 1} = style
    end

    test "detects space indentation and picks common width" do
      style = WhitespaceFitter.infer_indent_style(["  foo()", "    bar()"])
      # Both lines are indented with spaces; width is chosen from observed counts.
      assert %{type: :spaces, width: width} = style
      assert is_integer(width) and width >= 1
    end

    test "prefers tabs when tabs dominate mixed indentation" do
      lines = [
        "\tfoo()",
        "\t\tbar()",
        "    baz()"
      ]
      style = WhitespaceFitter.infer_indent_style(lines)
      assert %{type: :tabs, width: 1} = style
    end

    test "prefers spaces when spaces dominate mixed indentation" do
      lines = [
        "    foo()",
        "        bar()",
        "\tqux()"
      ]
      style = WhitespaceFitter.infer_indent_style(lines)
      assert %{type: :spaces, width: width} = style
      assert is_integer(width) and width >= 1
    end
  end

  describe "fit/4" do
    test "preserves relative indentation of new hunk and anchors to original" do
      context_before = ["defmodule Example do", "  def foo do"]
      orig_hunk = ["    old_call()"]
      context_after = ["  end", "end"]

      # New hunk uses 4-space indentation, but the file uses 2-space indentation.
      new_hunk_raw = "    new_call()\n        another_call()"

      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)

      # We expect the top line to stay at the same depth as the original hunk
      # (4 spaces), and the second line to be one level deeper using the
      # inferred style (likely 2-space indents).
      assert fitted =~ "    new_call()"
      assert fitted =~ "      another_call()"
    end

    test "falls back to neighbors when original hunk is empty" do
      context_before = ["defmodule Example do", "  def foo do"]
      orig_hunk = []
      context_after = ["  end", "end"]

      new_hunk_raw = "    inserted()"

      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)

      # In this case we expect the inserted line to align with the inner block
      # itself (two spaces beyond the module definition's indentation).
      assert String.starts_with?(fitted, "  inserted()")
    end

    test "handles all-blank new hunk as blank" do
      context_before = ["defmodule Example do"]
      orig_hunk = ["  def foo do", "    old_call()", "  end"]
      context_after = ["end"]

      new_hunk_raw = "\n\n"

      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)

      # Should preserve the fact that there are blank lines, but not try to
      # introduce any content.
      assert fitted == "\n\n"
    end

    test "fits Go-like tab-indented context when replacement uses spaces" do
      # Go style: tabs for indentation
      context_before = [
        "package main",
        "",
        "import \"fmt\"",
        "",
        "func main() {",
        "\tfmt.Println(\"hello\")"
      ]

      orig_hunk = ["\tfmt.Println(\"hello\")"]
      context_after = ["}"]

      # LLM-produced replacement using spaces instead of tabs
      new_hunk_raw = "    fmt.Println(\"hi\")\n        fmt.Println(\"there\")"

      # We expect the fitted hunk to start with tabs, not spaces, and to
      # preserve the relative indentation between the two lines.
      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)
      [line1, line2] = String.split(fitted, "\n", trim: false)
      assert line1 == "\tfmt.Println(\"hi\")"
      assert line2 == "\t\tfmt.Println(\"there\")"
    end

    test "fits Python-like 4-space-indented context when replacement uses tabs" do
      # Python style: 4 spaces per indent level
      context_before = [
        "def foo(x, y):",
        "    if x > y:",
        "        return x",
        "    return y"
      ]

      orig_hunk = [
        "    if x > y:",
        "        return x"
      ]

      context_after = ["    return y"]

      # LLM-produced replacement using tabs instead of spaces
      new_hunk_raw = "\tif x < y:\n\t\treturn y"

      # Expect 4-space indentation for the if-statement and 8 for the body
      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)
      [line1, line2] = String.split(fitted, "\n", trim: false)
      assert line1 == "    if x < y:"
      assert line2 == "        return y"
    end

    test "preserves fine-grained relative indentation for space-indented contexts" do
      context_before = [
        "def foo(x, y):",
        "    if x > y:",
        "        return x"
      ]
      orig_hunk = ["    if x > y:"]
      context_after = ["    return x"]
      new_hunk_raw = "    a()\n      b()\n        c()"
      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)
      [line1, line2, line3] = String.split(fitted, "\n", trim: false)
      assert line1 == "    a()"
      assert line2 == "      b()"
      assert line3 == "        c()"
    end

    test "preserves relative indentation for multi-level tab-indented contexts" do
      context_before = ["func main() {", "\tif cond {", "\t\tfoo()", "\t}"]
      orig_hunk = ["\t\tfoo()"]
      context_after = ["\t}"]
      new_hunk_raw = "\t\tfoo()\n\t\t\tbar()\n\t\t\t\tbaz()"
      fitted = WhitespaceFitter.fit(context_before, orig_hunk, context_after, new_hunk_raw)
      [line1, line2, line3] = String.split(fitted, "\n", trim: false)
      assert line1 == "\t\tfoo()"
      assert line2 == "\t\t\tbar()"
      assert line3 == "\t\t\t\tbaz()"
    end
  end
end
