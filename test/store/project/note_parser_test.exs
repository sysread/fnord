defmodule Store.Project.NoteParserTest do
  use ExUnit.Case

  describe "parse/1" do
    test ~S|{topic foo {fact bar}}| do
      assert {:ok, {"foo", ["bar"]}} == Store.Project.NoteParser.parse(~S|{topic foo {fact bar}}|)
    end

    test ~S|{topic foo {fact bar} {fact baz}}| do
      assert {:ok, {"foo", ["bar", "baz"]}} ==
               Store.Project.NoteParser.parse(~S|{topic foo {fact bar} {fact baz}}|)
    end

    test ~S|{topic "foo" {fact "bar"}}| do
      assert {:ok, {"foo", ["bar"]}} ==
               Store.Project.NoteParser.parse(~S|{topic "foo" {fact "bar"}}|)
    end

    test ~S|{topic "foo" {fact "bar"} {fact "baz"}}| do
      assert {:ok, {"foo", ["bar", "baz"]}} ==
               Store.Project.NoteParser.parse(~S|{topic "foo" {fact "bar"} {fact "baz"}}|)
    end

    test ~S|{topic "foo"{fact bar}{fact "baz"}}| do
      assert {:ok, {"foo", ["bar", "baz"]}} ==
               Store.Project.NoteParser.parse(~S|{topic "foo"{fact bar}{fact "baz"}}|)
    end
  end

  describe "parse/1 failure modes" do
    test ~S|fnord| do
      assert {:error, :invalid_format, :topic} == Store.Project.NoteParser.parse(~S|fnord|)
    end

    test ~S|{topic foo}| do
      assert {:error, :invalid_format, :facts} == Store.Project.NoteParser.parse(~S|{topic foo}|)
    end

    test ~S|{topic foo {}}| do
      assert {:error, :invalid_format, :facts} ==
               Store.Project.NoteParser.parse(~S|{topic foo {}}|)
    end

    test ~S|{topic foo {fact}}| do
      assert {:error, :invalid_format, :facts} ==
               Store.Project.NoteParser.parse(~S|{topic foo {fact}}|)
    end
  end
end
