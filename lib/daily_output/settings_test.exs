defmodule DailyOutput.SettingsTest do
  use DailyOutput.DataCase

  alias DailyOutput.Settings
  alias DailyOutput.Settings.Config

  setup do
    # Clean up any existing settings
    DailyOutput.Repo.delete_all(Config)
    :ok
  end

  describe "ensure_config/0" do
    test "creates default config when none exists" do
      assert {:ok, %Config{target_language: "de"}} = Settings.ensure_config()
    end

    test "returns existing config" do
      {:ok, _} = Settings.ensure_config()
      {:ok, config} = Settings.ensure_config()
      assert config.id
    end
  end

  describe "get_config/0" do
    test "returns empty config struct when none exists" do
      config = Settings.get_config()
      assert %Config{} = config
      assert is_nil(config.id)
    end

    test "returns saved config" do
      {:ok, _} = Settings.ensure_config()
      config = Settings.get_config()
      assert config.id
    end
  end

  describe "update_config/2" do
    test "updates fields" do
      {:ok, config} = Settings.ensure_config()

      {:ok, updated} =
        Settings.update_config(config, %{about_you: "I sing.", language_level: "C1"})

      assert updated.about_you == "I sing."
      assert updated.language_level == "C1"
    end

    test "validates the theme" do
      {:ok, config} = Settings.ensure_config()
      assert {:error, changeset} = Settings.update_config(config, %{theme: "neon"})
      assert %{theme: _} = errors_on(changeset)
    end
  end

  describe "change_config/2" do
    test "returns changeset" do
      {:ok, config} = Settings.ensure_config()
      changeset = Settings.change_config(config, %{language_level: "A2"})
      assert changeset.valid?
    end
  end

  describe "defaults" do
    test "has sensible defaults" do
      {:ok, config} = Settings.ensure_config()
      assert config.target_language == "de"
      assert config.native_language == "en"
      assert config.language_level == "B2"
      assert config.about_you == ""
      assert config.ai_provider == "direct"
      assert config.ai_model == "gpt-6.1-sol"
    end
  end

  describe "ai model/provider" do
    test "accepts the supported provider and model choices" do
      {:ok, config} = Settings.ensure_config()

      {:ok, updated} =
        Settings.update_config(config, %{ai_provider: "openrouter", ai_model: "gpt-6-luna"})

      assert updated.ai_provider == "openrouter"
      assert updated.ai_model == "gpt-6-luna"
    end

    test "rejects unknown provider or model" do
      {:ok, config} = Settings.ensure_config()
      assert {:error, cs} = Settings.update_config(config, %{ai_provider: "bogus"})
      assert %{ai_provider: _} = errors_on(cs)
      assert {:error, cs} = Settings.update_config(config, %{ai_model: "gpt-9"})
      assert %{ai_model: _} = errors_on(cs)
    end
  end
end
