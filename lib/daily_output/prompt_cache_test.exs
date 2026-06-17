defmodule DailyOutput.PromptCacheTest do
  use DailyOutput.DataCase

  alias DailyOutput.{Cache, PromptCache}

  @prompts [%{"prompt" => "Was machst du?", "translation" => "What are you doing?"}]

  test "round-trips a list" do
    assert PromptCache.put(:prompts, ["work"], "de", "en", @prompts) == @prompts
    assert PromptCache.get(:prompts, ["work"], "de", "en") == @prompts
  end

  test "returns nil when nothing is cached" do
    assert is_nil(PromptCache.get(:prompts, ["work"], "de", "en"))
  end

  test "keys are scoped by kind, languages and topics" do
    PromptCache.put(:prompts, ["work"], "de", "en", @prompts)

    assert is_nil(PromptCache.get(:openers, ["work"], "de", "en"))
    assert is_nil(PromptCache.get(:prompts, ["hobbies"], "de", "en"))
    assert is_nil(PromptCache.get(:prompts, ["work"], "fr", "en"))
    assert is_nil(PromptCache.get(:prompts, ["work"], "de", "de"))
  end

  test "multiple topics round-trip" do
    PromptCache.put(:prompts, ["work", "food"], "de", "en", @prompts)
    assert PromptCache.get(:prompts, ["work", "food"], "de", "en") == @prompts
  end

  test "expired entries are dropped" do
    PromptCache.put(:prompts, [], "de", "en", @prompts)

    DailyOutput.Repo.update_all(
      from(c in Cache, where: like(c.key, "prompts:%")),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert is_nil(PromptCache.get(:prompts, [], "de", "en"))
  end
end
