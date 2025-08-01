defmodule AI.Tools.Shell.UtilTest do
  use Fnord.TestCase, async: true

  alias AI.Tools.Shell.Util

  test "accepts simple valid commands" do
    Enum.each(
      [
        "ls -l",
        "echo hello",
        "cat file.txt",
        "grep foo bar",
        "ls -la /tmp",
        "touch a_b-c.txt",
        "echo \"foo | bar\"",
        "echo '&&'",
        "echo ';'",
        "echo '>'",
        "echo \"<\"",
        # double quote escaped in double quotes
        "echo \"\\\"\"",
        "echo '$()'",
        "echo '`uname`'"
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "should accept: #{cmd}"
      end
    )
  end

  test "rejects bad constructs" do
    Enum.each(
      [
        "ls | grep foo",
        "echo a && echo b",
        "doit || fail",
        "ls > out",
        "cat < in",
        "cat 2> error",
        "cat 1> error",
        "cat 2>> error",
        "cat 1>> error",
        "cat 2>&1",
        "cat 1>&2",
        "echo $(uname)",
        "echo `uname`",
        "foo <(bar)",
        "bar >(foo)",
        "do;ra",
        "cmd &",
        "   ls    |     grep foo   ",
        "\tls\t&&\techo bar",
        "echo foo; echo bar",
        "echo foo&"
      ],
      fn bad_cmd ->
        assert Util.contains_disallowed_syntax?(bad_cmd) == true,
               "should reject: #{bad_cmd}"
      end
    )
  end

  test "accepts forbidden chars inside quoted strings" do
    Enum.each(
      [
        "echo '|'",
        "echo \"|\"",
        "echo ';'",
        "echo \";\"",
        "echo '<'",
        "echo '>'",
        "echo '&&'",
        "echo \"&&\"",
        "echo '||'",
        "echo \"||\"",
        "echo '$()'",
        "echo \"`\"",
        "echo '`'",
        "echo '<(foo)'",
        "echo '>(foo)'",
        "echo 'cmd & bar'",
        "echo 'foo > bar < baz | qux'"
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "should accept quoted: #{cmd}"
      end
    )
  end

  test "accepts complex valid quoting" do
    Enum.each(
      [
        "echo \"abc '|' && \\`\""
        # Removed problematic case with unbalanced quotes: "echo 'abc \" | &&' \" && '"
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "should accept: #{cmd}"
      end
    )
  end

  test "rejects forbidden constructs outside quotes but not inside" do
    [
      {"echo | bar", true},
      {"echo 'foo' | bar", true},
      {"echo 'foo|bar'", false},
      {"'foo' | bar", true}
    ]
    |> Enum.each(fn {cmd, should_error} ->
      result = Util.contains_disallowed_syntax?(cmd)

      if should_error do
        assert result == true, "should reject: #{cmd}"
      else
        assert result == false, "should accept: #{cmd}"
      end
    end)
  end

  test "rejects command substitution inside double quotes" do
    Enum.each(
      [
        "echo \"$(uname)\"",
        "echo \"`uname`\""
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "should reject: #{cmd}"
      end
    )
  end

  test "rejects process substitution outside quotes" do
    Enum.each(
      [
        "foo <(bar)",
        "bar >(foo)"
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "should reject: #{cmd}"
      end
    )
  end

  test "does not reject escaped operators in double quotes" do
    Enum.each(
      [
        "echo \"foo \\| bar\"",
        "echo \"foo \\&\\& bar\""
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "should accept: #{cmd}"
      end
    )
  end

  test "does not allow escaped operators in unquoted input" do
    Enum.each(
      [
        "echo foo \\| bar",
        "echo foo \\; bar"
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == true,
               "should reject: #{cmd}"
      end
    )
  end

  test "accepts literal backslashes" do
    Enum.each(
      [
        "echo '\\\\'",
        "echo \"\\\\\""
      ],
      fn cmd ->
        assert Util.contains_disallowed_syntax?(cmd) == false,
               "should accept: #{cmd}"
      end
    )
  end

  test "edge-case commands" do
    # Multiline with backslash continuation should be rejected
    assert Util.contains_disallowed_syntax?("ls \\\n-lah") == true

    # Literal embedded newlines should be rejected
    assert Util.contains_disallowed_syntax?("ls\n-lah") == true

    # Unicode zero-width space between tokens should be rejected
    assert Util.contains_disallowed_syntax?("ls\u200B-lah") == true

    # Unicode inside quotes should be accepted
    assert Util.contains_disallowed_syntax?("echo 'héllo \u200B こんにちは'") == false

    # Unbalanced quotes should be rejected
    assert Util.contains_disallowed_syntax?("echo 'foo") == true

    # Here-document syntax should be rejected
    assert Util.contains_disallowed_syntax?("cat <<EOF\nfoo | bar\nEOF") == true

    # Octal/hex escape for special char should be rejected
    assert Util.contains_disallowed_syntax?("echo $'\\x7c'") == true

    # Unusual whitespace should be accepted
    assert Util.contains_disallowed_syntax?("   echo   'ok'   ") == false

    # NUL byte in the middle should be rejected
    assert Util.contains_disallowed_syntax?("ls\0-lah") == true
  end
end
