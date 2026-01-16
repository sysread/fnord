defmodule OutputsTest do
  use Fnord.TestCase, async: false

  describe "save/3" do
    setup do
      raw = "# Title: How to do X\nThis is the body content."
      mock_project("outputs_test")
      {:ok, project_struct} = Store.get_project("outputs_test")

      outputs_dir = Outputs.outputs_dir(project_struct.name)
      File.rm_rf!(outputs_dir)

      {:ok, project: project_struct, raw: raw}
    end

    test "outputs_dir/1 uses flattened ~/fnord/outputs/<project> layout", %{project: project} do
      expected = Path.join([Settings.get_user_home(), "fnord", "outputs", project.name])
      assert Outputs.outputs_dir(project.name) == expected
    end

    test "first save writes to slugged title file", %{project: project, raw: raw} do
      assert {:ok, path} = Outputs.save(project.name, raw)

      outputs_dir = Outputs.outputs_dir(project.name)
      expected_file = Path.join(outputs_dir, "how-to-do-x.md")

      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end

    test "slug collision appends suffix on second save", %{project: project, raw: raw} do
      {:ok, _} = Outputs.save(project.name, raw)
      assert {:ok, path} = Outputs.save(project.name, raw)

      outputs_dir = Outputs.outputs_dir(project.name)
      expected_file = Path.join(outputs_dir, "how-to-do-x-1.md")

      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end

    test "no title line with conversation_id option writes to conversation-abc123.md", %{
      project: project
    } do
      raw = "This content has no title line"
      outputs_dir = Outputs.outputs_dir(project.name)
      File.rm_rf!(outputs_dir)
      File.mkdir_p!(outputs_dir)
      assert {:ok, path} = Outputs.save(project.name, raw, conversation_id: "abc123")
      expected_file = Path.join(outputs_dir, "conversation-abc123.md")
      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end

    test "no title line without conversation_id option writes to untitled.md", %{project: project} do
      raw = "This content has no title line"
      outputs_dir = Outputs.outputs_dir(project.name)
      File.rm_rf!(outputs_dir)
      File.mkdir_p!(outputs_dir)
      assert {:ok, path} = Outputs.save(project.name, raw)
      expected_file = Path.join(outputs_dir, "untitled.md")
      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end

    test "conversation_id collision appends suffix on second save", %{project: project} do
      raw = "This content has no title line"
      outputs_dir = Outputs.outputs_dir(project.name)
      File.rm_rf!(outputs_dir)
      File.mkdir_p!(outputs_dir)
      {:ok, _} = Outputs.save(project.name, raw, conversation_id: "abc123")
      assert {:ok, path} = Outputs.save(project.name, raw, conversation_id: "abc123")
      expected_file = Path.join(outputs_dir, "conversation-abc123-1.md")
      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end

    test "untitled collision appends suffix on second save", %{project: project} do
      raw = "This content has no title line"
      outputs_dir = Outputs.outputs_dir(project.name)
      File.rm_rf!(outputs_dir)
      File.mkdir_p!(outputs_dir)
      {:ok, _} = Outputs.save(project.name, raw)
      assert {:ok, path} = Outputs.save(project.name, raw)
      expected_file = Path.join(outputs_dir, "untitled-1.md")
      assert path == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == raw
    end
  end

  describe "extract_title/1" do
    test "extracts title from the first line" do
      assert Outputs.extract_title("# Title: Hello World\nBody") == "Hello World"
    end

    test "returns nil when first line is not a title" do
      assert Outputs.extract_title("# Synopsis\n...") == nil
    end

    test "title matching is case-insensitive" do
      assert Outputs.extract_title("# title: Hello\nBody") == "Hello"
    end

    test "returns nil when title line has no actual title text" do
      assert Outputs.extract_title("# Title:   \nBody") == nil
    end

    test "trims whitespace around title" do
      assert Outputs.extract_title("# Title:   Hello   \nBody") == "Hello"
    end
  end
end
