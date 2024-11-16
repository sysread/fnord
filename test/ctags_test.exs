defmodule CtagsTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  describe "find_tags/2" do
    setup do
      # Create a temporary ctags file
      {:ok, tmp_dir} = Briefly.create(directory: true)
      tags_file_path = Path.join(tmp_dir, "tags")

      # Write a sample ctags file with the correct sorted order
      File.write!(tags_file_path, """
      !_TAG_FILE_FORMAT\t2\t/extended format/
      !_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/
      Apple\tfile1.ex\t/^defmodule Apple do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      Banana\tfile2.ex\t/^defmodule Banana do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      Grape\tfile3.ex\t/^defmodule Grape do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      Orange\tfile4.ex\t/^defmodule Orange do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      Pear\tfile5.ex\t/^defmodule Pear do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      Sample\tsample.ex\t/^defmodule Sample do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      hello\tsample.ex\t/^  def hello do$/;\"\tfunction\tlanguage:Elixir\tkind:function
      special_tag!@#\tfile6.ex\t/^defmodule Special do$/;\"\tmodule\tlanguage:Elixir\tkind:module
      world\tsample.ex\t/^  def world do$/;\"\tfunction\tlanguage:Elixir\tkind:function
      """)

      {:ok, %{tags_file_path: tags_file_path}}
    end

    test "finds an existing tag", %{tags_file_path: tags_file_path} do
      result = Ctags.find_tags(tags_file_path, "hello")

      assert result ==
               {:ok,
                [
                  %{
                    tagname: "hello",
                    filename: "sample.ex",
                    ex_command: "/^  def hello do$/",
                    kind: "function",
                    language: "Elixir"
                  }
                ]}
    end

    test "finds another existing tag", %{tags_file_path: tags_file_path} do
      result = Ctags.find_tags(tags_file_path, "Apple")

      assert result ==
               {:ok,
                [
                  %{
                    tagname: "Apple",
                    filename: "file1.ex",
                    ex_command: "/^defmodule Apple do$/",
                    kind: "module",
                    language: "Elixir"
                  }
                ]}
    end

    test "returns :not_found for a non-existing tag", %{tags_file_path: tags_file_path} do
      result = Ctags.find_tags(tags_file_path, "nonexistent")
      assert result == {:error, :tag_not_found}
    end

    test "returns {:error, reason} when file does not exist" do
      result = Ctags.find_tags("nonexistent_file", "hello")
      assert match?({:error, :tag_file_not_found}, result)
    end

    test "handles tags with special characters", %{tags_file_path: tags_file_path} do
      result = Ctags.find_tags(tags_file_path, "special_tag!@#")

      assert result ==
               {:ok,
                [
                  %{
                    tagname: "special_tag!@#",
                    filename: "file6.ex",
                    ex_command: "/^defmodule Special do$/",
                    kind: "module",
                    language: "Elixir"
                  }
                ]}
    end

    test "finds multiple matching tags, even with surrounding tags in sorted order", %{
      tags_file_path: tags_file_path
    } do
      # Append sorted entries with different and matching tagnames
      File.write!(
        tags_file_path,
        """
        !_TAG_FILE_FORMAT\t2\t/extended format/
        !_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/
        Alpha\talpha_file.ex\t/^defmodule Alpha do$/;\"\tmodule\tlanguage:Elixir\tkind:module
        Beta\tbeta_file.ex\t/^defmodule Beta do$/;\"\tmodule\tlanguage:Elixir\tkind:module
        Delta\tdelta_file.ex\t/^defmodule Delta do$/;\"\tmodule\tlanguage:Elixir\tkind:module
        Gamma\tgamma_file.ex\t/^defmodule Gamma do$/;\"\tmodule\tlanguage:Elixir\tkind:module
        hello\tsample1.ex\t/^  def hello do$/;\"\tfunction\tlanguage:Elixir\tkind:function
        hello\tsample2.ex\t/^  def hello_world do$/;\"\tfunction\tlanguage:Elixir\tkind:function
        hello\tsample3.ex\t/^  def hello_again do$/;\"\tfunction\tlanguage:Elixir\tkind:function
        special_tag!@#\tfile6.ex\t/^defmodule Special do$/;\"\tmodule\tlanguage:Elixir\tkind:module
        world\tsample.ex\t/^  def world do$/;\"\tfunction\tlanguage:Elixir\tkind:function
        """
      )

      # Call find_tags/2
      result = Ctags.find_tags(tags_file_path, "hello")

      # Assert the result contains all matching tags
      assert result ==
               {:ok,
                [
                  %{
                    tagname: "hello",
                    filename: "sample1.ex",
                    ex_command: "/^  def hello do$/",
                    kind: "function",
                    language: "Elixir"
                  },
                  %{
                    tagname: "hello",
                    filename: "sample2.ex",
                    ex_command: "/^  def hello_world do$/",
                    kind: "function",
                    language: "Elixir"
                  },
                  %{
                    tagname: "hello",
                    filename: "sample3.ex",
                    ex_command: "/^  def hello_again do$/",
                    kind: "function",
                    language: "Elixir"
                  }
                ]}
    end
  end

  describe "generate_tags/1" do
    setup do
      # Create a unique temporary directory for the project
      {:ok, project_dir} = Briefly.create(directory: true)

      # Save the original HOME environment variable
      original_home = System.get_env("HOME")

      # Override the HOME environment variable with the temporary directory
      System.put_env("HOME", project_dir)

      # Ensure the original HOME is restored after tests
      on_exit(fn ->
        if original_home do
          System.put_env("HOME", original_home)
        else
          System.delete_env("HOME")
        end
      end)

      # Create a temporary directory for code
      {:ok, code_dir} = Briefly.create(directory: true)

      # Create a sample Elixir file in the temporary directory
      code_dir
      |> Path.join("sample.ex")
      |> File.write!("""
      defmodule Sample do
        def hello do
          IO.puts("Hello, world!")
        end
      end
      """)

      # Index the project
      %{project: "test", directory: code_dir, quiet: true}
      |> Cmd.Indexer.new(MockAI)
      |> Cmd.Indexer.run()

      {:ok, %{project: "test"}}
    end

    test "generates tags file successfully", %{project: project} do
      store = Store.new(project)
      tags_file_path = store.path |> Path.join("tags")

      assert {:ok, ^tags_file_path} = Ctags.generate_tags(project)
      assert File.exists?(tags_file_path)

      tags_content = File.read!(tags_file_path)
      assert String.contains?(tags_content, "Sample")
      assert String.contains?(tags_content, "hello")
    end

    test "returns an error when ctags executable is not found", %{project: project} do
      # Backup the original PATH
      original_path = System.get_env("PATH")

      # Set PATH to an empty string to simulate ctags not being found
      System.put_env("PATH", "")

      # Expect the function to return an error tuple
      {:error, reason} = Ctags.generate_tags(project)

      # Check that the error message contains the expected text
      assert String.contains?(reason, "ctags executable not found in PATH")

      # Restore the original PATH
      System.put_env("PATH", original_path)
    end
  end

  defmodule MockAI do
    defstruct []

    @behaviour AI

    @impl AI
    def new() do
      %MockAI{}
    end

    @impl AI
    def get_embeddings(_ai, _text) do
      {:ok, ["embedding1", "embedding2"]}
    end

    @impl AI
    def get_summary(_ai, _file, _text) do
      {:ok, "summary"}
    end
  end
end
