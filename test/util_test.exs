defmodule UtilTest do
  use Fnord.TestCase, async: true

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
end
