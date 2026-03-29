defmodule Sprachjournal.JournalTest do
  use Sprachjournal.DataCase

  alias Sprachjournal.Journal
  alias Sprachjournal.Journal.Entry

  defp create_entry(attrs \\ %{}) do
    {:ok, entry} =
      Journal.create_entry(Map.merge(%{body: "Test eintrag", language: "de"}, attrs))

    entry
  end

  describe "create_entry/1" do
    test "creates with valid attrs" do
      assert {:ok, %Entry{body: "Hallo Welt", language: "de"}} =
               Journal.create_entry(%{body: "Hallo Welt", language: "de"})
    end

    test "defaults language to de" do
      assert {:ok, %Entry{language: "de"}} = Journal.create_entry(%{body: "test"})
    end
  end

  describe "get_entry!/1" do
    test "returns entry by id" do
      entry = create_entry()
      assert Journal.get_entry!(entry.id).id == entry.id
    end

    test "excludes soft-deleted entries" do
      entry = create_entry()
      {:ok, _} = Journal.soft_delete_entry(entry)
      assert_raise Ecto.NoResultsError, fn -> Journal.get_entry!(entry.id) end
    end
  end

  describe "update_entry/2" do
    test "updates body" do
      entry = create_entry()
      {:ok, updated} = Journal.update_entry(entry, %{body: "Neuer text"})
      assert updated.body == "Neuer text"
    end
  end

  describe "complete_entry/1" do
    test "sets completed_at" do
      entry = create_entry()
      assert is_nil(entry.completed_at)
      {:ok, completed} = Journal.complete_entry(entry)
      refute is_nil(completed.completed_at)
    end
  end

  describe "save_feedback/2" do
    test "stores feedback map" do
      entry = create_entry()
      feedback = %{"annotated_text" => "test", "annotations" => []}
      {:ok, updated} = Journal.save_feedback(entry, feedback)
      assert updated.feedback["annotated_text"] == "test"
    end
  end

  describe "soft_delete_entry/1" do
    test "sets deleted_at without destroying" do
      entry = create_entry()
      {:ok, deleted} = Journal.soft_delete_entry(entry)
      refute is_nil(deleted.deleted_at)
      assert Sprachjournal.Repo.get(Entry, entry.id)
    end
  end

  describe "word_count/1" do
    test "counts words" do
      assert Journal.word_count(%Entry{body: "eins zwei drei"}) == 3
    end

    test "handles nil" do
      assert Journal.word_count(%Entry{body: nil}) == 0
    end

    test "handles empty" do
      assert Journal.word_count(%Entry{body: ""}) == 0
    end
  end

  describe "get_today_entry/0" do
    test "returns an entry from today" do
      create_entry(%{body: "first"})
      create_entry(%{body: "second"})
      assert Journal.get_today_entry()
    end

    test "excludes deleted entries" do
      entry = create_entry()
      {:ok, _} = Journal.soft_delete_entry(entry)
      assert is_nil(Journal.get_today_entry())
    end

    test "returns nil when no entries" do
      assert is_nil(Journal.get_today_entry())
    end
  end

  describe "versioning" do
    test "get_versions returns all entries for the same day" do
      e1 = create_entry(%{body: "v1"})
      e2 = create_entry(%{body: "v2"})
      versions = Journal.get_versions(e1)
      assert length(versions) == 2
      ids = Enum.map(versions, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])
    end

    test "version_info returns total count" do
      _e1 = create_entry(%{body: "v1"})
      e2 = create_entry(%{body: "v2"})
      {_version, total} = Journal.version_info(e2)
      assert total == 2
    end

    test "deleted entries excluded from versions" do
      e1 = create_entry(%{body: "v1"})
      e2 = create_entry(%{body: "v2"})
      {:ok, _} = Journal.soft_delete_entry(e1)
      assert {1, 1} = Journal.version_info(e2)
    end
  end

  describe "list_recent_entries/1" do
    test "excludes today" do
      create_entry(%{body: "today"})
      assert Journal.list_recent_entries(14) == []
    end
  end

  describe "current_streak/0" do
    test "returns 0 with no entries" do
      assert Journal.current_streak() == 0
    end
  end
end
