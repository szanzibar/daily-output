defmodule DailyOutput.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DailyOutput.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias DailyOutput.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DailyOutput.DataCase
    end
  end

  setup tags do
    DailyOutput.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DailyOutput.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Answers the next AI call the way OpenAI's Responses API does: a string is the reply text,
  a map the structured object, sent as the forced tool's call. The request body comes to
  the test as `{:ai_request, body}`.
  """
  def expect_ai(reply) do
    test = self()

    output =
      if is_binary(reply) do
        %{
          "id" => "msg_test",
          "type" => "message",
          "status" => "completed",
          "content" => [
            %{"type" => "output_text", "annotations" => [], "logprobs" => [], "text" => reply}
          ],
          "phase" => "final_answer",
          "role" => "assistant"
        }
      else
        %{
          "id" => "fc_test",
          "type" => "function_call",
          "status" => "completed",
          "arguments" => Jason.encode!(reply),
          "call_id" => "call_test",
          "name" => "structured_output"
        }
      end

    Req.Test.expect(DailyOutput.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:ai_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "resp_test",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-6.1-sol",
        "output" => [output],
        "usage" => %{
          "input_tokens" => 100,
          "input_tokens_details" => %{"cache_write_tokens" => 0, "cached_tokens" => 0},
          "output_tokens" => 20,
          "output_tokens_details" => %{"reasoning_tokens" => 0},
          "total_tokens" => 120
        }
      })
    end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
