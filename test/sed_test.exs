defmodule SedTest do
  use Fnord.TestCase

  setup do
    {:ok, tmp} = Briefly.create()

    File.write!(tmp, """
    The quick brown fox
    jumps over the lazy dog
    HELLO world
    Hello World
    foo bar baz
    """)

    %{tmp_file: tmp}
  end

  test "simple substitution across whole file", %{tmp_file: file} do
    edit = %{"pattern" => "brown", "replacement" => "red", "flags" => "g"}

    assert :ok = Sed.run(file, edit)

    content = File.read!(file)
    assert content =~ "red fox"
    refute content =~ "brown"
  end

  test "line range substitution (case-insensitive)", %{tmp_file: file} do
    edit = %{
      "pattern" => "hello",
      "replacement" => "hi",
      "flags" => "gi",
      "line_start" => 1,
      "line_end" => 2
    }

    assert :ok = Sed.run(file, edit)

    content = File.read!(file)
    # Only first two lines affected, so HELLO and Hello in lines 3 & 4 remain unchanged
    assert content =~ "The quick brown fox"
    assert content =~ "jumps over the lazy dog"
    # The substitutions would not affect line 3 and 4
    assert content =~ "HELLO world"
    assert content =~ "Hello World"
  end

  test "replacement with flags and whole file", %{tmp_file: file} do
    edit = %{"pattern" => "foo", "replacement" => "bar", "flags" => "g"}

    assert :ok = Sed.run(file, edit)

    content = File.read!(file)
    assert content =~ "bar bar baz"
  end

  test "returns error on bad pattern", %{tmp_file: file} do
    bad_edit = %{"pattern" => "[", "replacement" => "x"}

    assert {:error, msg} = Sed.run(file, bad_edit)
    assert msg =~ "sed failed"
  end
end
