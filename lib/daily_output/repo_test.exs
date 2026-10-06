defmodule DailyOutput.RepoTest do
  use DailyOutput.DataCase, async: true

  test "tests run in a manual sandbox, so a process nobody allowed can't reach the DB" do
    test = self()
    spawn(fn -> send(test, catch_error(Repo.all(DailyOutput.Settings.Config))) end)
    assert_receive %DBConnection.OwnershipError{}
  end
end
