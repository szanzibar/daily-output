defmodule DailyOutput.CacheTest do
  use DailyOutput.DataCase

  alias DailyOutput.Cache

  describe "put/2 and get/2" do
    test "stores and retrieves a value" do
      Cache.put("test_key", "test_value")
      assert Cache.get("test_key") == "test_value"
    end

    test "overwrites existing value" do
      Cache.put("key", "old")
      Cache.put("key", "new")
      assert Cache.get("key") == "new"
    end

    test "returns nil for missing key" do
      assert is_nil(Cache.get("nonexistent"))
    end
  end

  describe "TTL" do
    test "returns nil for expired entries" do
      Cache.put("old_key", "old_value")

      # Manually backdate the updated_at
      DailyOutput.Repo.update_all(
        from(c in Cache, where: c.key == "old_key"),
        set: [updated_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert is_nil(Cache.get("old_key", 86400))
    end

    test "returns value within TTL" do
      Cache.put("fresh_key", "fresh_value")
      assert Cache.get("fresh_key", 86400) == "fresh_value"
    end
  end
end
