defmodule TomlTest do
  use Fnord.TestCase, async: false

  describe "decode/1" do
    test "decodes a TOML document into a map" do
      assert {:ok, %{"a" => 1, "b" => %{"c" => "d"}}} =
               Fnord.Toml.decode("""
               a = 1

               [b]
               c = "d"
               """)
    end

    test "returns a structured error for invalid TOML" do
      assert {:error, {:toml_decode_error, msg}} = Fnord.Toml.decode("a = ")
      assert is_binary(msg)
      assert msg != ""
    end
  end

  describe "decode_file/1" do
    test "returns a structured error for missing file" do
      assert {:error, {:toml_file_error, path, :enoent}} =
               Fnord.Toml.decode_file("/nope/nope.toml")

      assert path == "/nope/nope.toml"
    end

    test "reads and decodes a file" do
      {:ok, dir} = tmpdir()
      path = Path.join(dir, "example.toml")
      File.write!(path, "a = 1\n")

      assert {:ok, %{"a" => 1}} = Fnord.Toml.decode_file(path)
    end
  end
end
