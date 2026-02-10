defmodule UtilTest do
  use Fnord.TestCase, async: false

  test "expand_path/2" do
    assert Util.expand_path("foo/bar") == Path.expand("foo/bar")
    assert Util.expand_path("foo/../bar") == Path.expand("bar")
    assert Util.expand_path("foo/./bar") == Path.expand("foo/bar")
    assert Util.expand_path("foo/../bar", "/tmp") == Path.expand("bar", "/tmp")
    assert Util.expand_path("foo/../bar", nil) == Path.expand("bar")
  end

  describe "resolve_symlink/3" do
    setup do
      {:ok, tmp_dir} = Briefly.create(directory: true)
      %{tmp_dir: tmp_dir}
    end

    test "resolves absolute symlink target", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "file.txt")
      File.write!(file, "hello")

      symlink = Path.join(tmp_dir, "link")
      File.ln_s!(file, symlink)

      assert Util.resolve_symlink(symlink) == {:ok, file}
    end

    test "resolves relative symlink target", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "file.txt")
      File.write!(file, "hello")

      symlink = Path.join(tmp_dir, "rel_link")
      File.ln_s!("file.txt", symlink)

      assert Util.resolve_symlink(symlink) == {:ok, file}
    end

    test "follows nested symlink chain", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "file.txt")
      File.write!(file, "hello")

      link1 = Path.join(tmp_dir, "link1")
      File.ln_s!(file, link1)

      link2 = Path.join(tmp_dir, "link2")
      File.ln_s!(link1, link2)

      assert Util.resolve_symlink(link2) == {:ok, file}
    end

    test "detects circular symlink", %{tmp_dir: tmp_dir} do
      circular1 = Path.join(tmp_dir, "circular1")
      circular2 = Path.join(tmp_dir, "circular2")

      File.ln_s!(circular2, circular1)
      File.ln_s!(circular1, circular2)

      assert Util.resolve_symlink(circular1) == {:error, :circular_symlink}
    end

    test "returns error for non-existent path", %{tmp_dir: tmp_dir} do
      non_existent = Path.join(tmp_dir, "nope")

      assert {:error, _} = Util.resolve_symlink(non_existent)
    end
  end

  describe "path_within_root?/2" do
    test "true when path is inside root" do
      {:ok, root} = Briefly.create(directory: true)
      subdir = Path.join(root, "subdir")
      File.mkdir_p!(subdir)
      assert Util.path_within_root?(subdir, root) == true
    end

    test "false when path is outside root" do
      {:ok, root} = Briefly.create(directory: true)
      {:ok, other} = Briefly.create(directory: true)
      assert Util.path_within_root?(other, root) == false
    end

    test "true when path equals root" do
      {:ok, root} = Briefly.create(directory: true)
      assert Util.path_within_root?(root, root) == true
    end

    test "handles symlink inside root" do
      {:ok, root} = Briefly.create(directory: true)
      target = Path.join(root, "target_dir")
      File.mkdir_p!(target)

      symlink = Path.join(root, "link_dir")
      :ok = File.ln_s(target, symlink)

      assert Util.path_within_root?(symlink, root) == true
    end

    test "handles symlink outside root" do
      {:ok, root} = Briefly.create(directory: true)
      {:ok, external} = Briefly.create(directory: true)

      symlink = Path.join(root, "link_outside")
      :ok = File.ln_s(external, symlink)

      assert Util.path_within_root?(symlink, root) == false
    end
  end

  describe "get_latest_version" do
    setup do
      :meck.new(HTTPoison, [:no_link, :passthrough])
      on_exit(fn -> :meck.unload(HTTPoison) end)
      :ok
    end

    test "returns {:ok, version} when API returns 200 and valid JSON" do
      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"latest_version":"1.2.3"})}}
      end)

      assert Util.get_latest_version() == {:ok, "1.2.3"}
    end

    test "returns :error when API returns 200 but invalid JSON" do
      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200, body: "invalid json"}}
      end)

      assert Util.get_latest_version() == :error
    end

    test "returns {:error, :api_request_failed} and warns when non-200 status code" do
      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 500, body: ""}}
      end)

      capture_all(fn ->
        assert {:error, :api_request_failed} = Util.get_latest_version()
      end)
    end

    test "returns {:error, reason} and warns when transport error occurs" do
      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :timeout}}
      end)

      capture_all(fn ->
        assert Util.get_latest_version() == {:error, :timeout}
      end)
    end
  end

  describe "truncate/2" do
    setup do
      # Ensure no leftover environment variable
      System.delete_env("FNORD_LOGGER_LINES")
      :ok
    end

    test "falls back to argument when env var unset" do
      # input has 4 lines, argument is 2
      input = Enum.map(1..4, &"line#{&1}") |> Enum.join("\n")
      result = Util.truncate(input, 2) |> String.trim()
      # should keep only the first 2 lines, omit the rest
      assert String.split(result, "\n") == ["line1", "line2", "...plus 2 additional lines"]
    end

    test "uses valid positive FNORD_LOGGER_LINES over argument" do
      # input has 5 lines, env var set to 3, argument is 1
      input = Enum.map(1..5, &"l#{&1}") |> Enum.join("\n")
      Util.Env.put_env("FNORD_LOGGER_LINES", "3")
      result = Util.truncate(input, 1) |> String.trim()
      lines = String.split(result, "\n")
      # first 3 lines from env var
      assert Enum.slice(lines, 0, 3) == ["l1", "l2", "l3"]
      # omission message indicates 2 remaining
      assert List.last(lines) =~ ~r/...plus 2 additional lines/
      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "invalid FNORD_LOGGER_LINES falls back to positive argument" do
      # input has 3 lines, env var "foo" invalid, argument 1
      input = Enum.map(1..3, &"x#{&1}") |> Enum.join("\n")
      Util.Env.put_env("FNORD_LOGGER_LINES", "foo")
      result = Util.truncate(input, 1) |> String.trim()
      # should use argument = 1, omit 2 lines
      assert String.split(result, "\n") == ["x1", "...plus 2 additional lines"]
      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "falls back to argument when FNORD_LOGGER_LINES is negative" do
      # input has 5 lines, env var set to "-2", argument is 3
      input = Enum.map(1..5, &"l#{&1}") |> Enum.join("\n")
      Util.Env.put_env("FNORD_LOGGER_LINES", "-2")
      result = Util.truncate(input, 3) |> String.trim()
      lines = String.split(result, "\n")
      # first 3 lines from argument
      assert Enum.slice(lines, 0, 3) == ["l1", "l2", "l3"]
      # omission message indicates 2 remaining
      assert List.last(lines) =~ ~r/...plus 2 additional lines/
      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "invalid env and non-positive argument falls back to default 50" do
      # generate 60 lines
      input = Enum.map(1..60, &"z#{&1}") |> Enum.join("\n")
      Util.Env.put_env("FNORD_LOGGER_LINES", "0")
      # argument 0 is non-positive; default is 50
      result = Util.truncate(input, 0) |> String.trim()
      lines = String.split(result, "\n")
      # 50 kept + 1 omission line = 51 elements
      assert length(lines) == 51
      # omission should mention 10 remaining
      assert List.last(lines) =~ ~r/...plus 10 additional lines/
      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "falls back to default 50 when argument is negative and env var unset" do
      # generate 60 lines
      input = Enum.map(1..60, &"z#{&1}") |> Enum.join("\n")
      # FNORD_LOGGER_LINES unset by setup
      result = Util.truncate(input, -5) |> String.trim()
      lines = String.split(result, "\n")
      # default 50 kept + 1 omission line = 51 elements
      assert length(lines) == 51
      # omission should mention 10 remaining
      assert List.last(lines) =~ ~r/...plus 10 additional lines/
    end

    test "no truncation when input shorter than limit" do
      input = "a\nb\nc"
      assert Util.truncate(input, 5) |> String.trim() == input
    end

    test "no truncation when input exactly equals limit" do
      input = Enum.map(1..4, &"n#{&1}") |> Enum.join("\n")
      assert Util.truncate(input, 4) |> String.trim() == input
    end

    test "handles mixed CRLF and LF line endings" do
      input = "r1\r\n r2\n r3\r\n r4"
      result = Util.truncate(input, 2) |> String.trim()
      assert String.split(result, "\n") == ["r1", " r2", "...plus 2 additional lines"]
    end

    test "empty input returns empty" do
      assert Util.truncate("", 3) |> String.trim() == ""
    end

    test "env var overrides even when argument is larger" do
      input = Enum.map(1..5, &"L#{&1}") |> Enum.join("\n")
      Util.Env.put_env("FNORD_LOGGER_LINES", "3")

      assert String.split(Util.truncate(input, 5) |> String.trim(), "\n") == [
               "L1",
               "L2",
               "L3",
               "...plus 2 additional lines"
             ]

      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "blank FNORD_LOGGER_LINES falls back to argument" do
      input = "a\nb\nc"
      Util.Env.put_env("FNORD_LOGGER_LINES", "")

      assert String.split(Util.truncate(input, 2) |> String.trim(), "\n") == [
               "a",
               "b",
               "...plus 1 additional lines"
             ]

      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "partial parse \"3.5\" of FNORD_LOGGER_LINES ignores suffix" do
      input = "x\nx\nx\nx"
      Util.Env.put_env("FNORD_LOGGER_LINES", "3.5")

      assert String.split(Util.truncate(input, 3) |> String.trim(), "\n") == [
               "x",
               "x",
               "x",
               "...plus 1 additional lines"
             ]

      System.delete_env("FNORD_LOGGER_LINES")
    end

    test "omission message appears when exactly one line is omitted" do
      input = "1\n2\n3"
      [_, _, omission] = String.split(Util.truncate(input, 2) |> String.trim(), "\n")
      assert omission =~ "...plus 1 additional lines"
    end
  end
end
