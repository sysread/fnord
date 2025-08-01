defmodule AI.Tools.ShellTest do
  use Fnord.TestCase, async: true

  alias AI.Tools.Shell

  @valid_desc "Test"

  test "rejects empty or all-whitespace commands" do
    Enum.each(["", " ", "\t", "\n"], fn cmd ->
      result = Shell.read_args(%{"description" => @valid_desc, "cmd" => cmd})
      assert match?({:error, _, _}, result), "should reject: #{inspect(cmd)}"
    end)
  end

  test "rejects empty description" do
    result = Shell.read_args(%{"description" => "", "cmd" => "ls"})
    assert match?({:error, _, _}, result), "should reject empty description"
  end

  test "accepts valid commands with proper arguments" do
    result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "ls -l"})
    assert {:ok, %{"description" => @valid_desc, "cmd" => "ls -l"}} = result
  end

  test "trims command whitespace" do
    result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "  ls -l  "})
    assert {:ok, %{"description" => @valid_desc, "cmd" => "ls -l"}} = result
  end

  test "delegates dangerous syntax checking to utility module" do
    # Test that dangerous commands are rejected via the utility module
    result = Shell.read_args(%{"description" => @valid_desc, "cmd" => "ls | grep foo"})
    assert {:error, msg} = result

    assert msg ==
             "Only simple, direct commands are permitted: no pipes, logical operators, redirection, subshells, or command chaining."
  end
end
