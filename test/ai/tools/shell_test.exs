defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: true

  alias AI.Tools.Shell

  @valid_desc "Test"
  @msg "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."

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
        # single quote escaped in double quotes
        "echo '\\''",
        # double quote escaped in double quotes
        "echo \"\\\"\"",
        "echo '$()'",
        "echo '`uname`'"
      ],
      fn cmd ->
        assert {:ok, _} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
        assert {:error, @msg} =
                 Shell.read_args(%{"description" => @valid_desc, "cmd" => bad_cmd}),
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
        assert {:ok, _} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
               "should accept quoted: #{cmd}"
      end
    )
  end

  test "accepts complex valid quoting" do
    Enum.each(
      [
        "echo \"abc '|' && \\`\"",
        "echo 'abc \" | &&' \" && '"
      ],
      fn cmd ->
        assert {:ok, _} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd})

      if should_error do
        assert {:error, @msg} = result, "should reject: #{cmd}"
      else
        assert {:ok, _} = result, "should accept: #{cmd}"
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
        assert {:error, @msg} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
        assert {:error, @msg} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
        assert {:ok, _} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
        assert {:error, @msg} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
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
        assert {:ok, _} = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd}),
               "should accept: #{cmd}"
      end
    )
  end

  test "rejects empty or all-whitespace commands" do
    Enum.each(["", " ", "\t", "\n"], fn cmd ->
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd})
      assert match?({:error, _, _}, result), "should reject: #{inspect(cmd)}"
    end)
  end
end
