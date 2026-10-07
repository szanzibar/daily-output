defmodule DailyOutput.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ReqLLM's model catalog loads lazily and takes over a second, so warm it here instead of
    # in the first AI call after a boot.
    {:ok, _} = LLMDB.load()

    children =
      [
        DailyOutput.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:daily_output, :ecto_repos), skip: skip_migrations?()}
      ] ++
        vapid_child() ++
        [
          {Phoenix.PubSub, name: DailyOutput.PubSub},
          # Start to serve requests, typically the last entry
          DailyOutputWeb.Endpoint
        ] ++ reminders_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DailyOutput.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Releases only, right after they migrate: the key follows the model picked in Settings,
    # and dev keeps Phoenix's pending-migrations page.
    unless skip_migrations?(), do: DailyOutput.AI.warn_if_key_missing()
    {:ok, pid}
  end

  # Generates/loads the VAPID keypair right after migrations, before we serve
  # requests. Tests set their own keys inside their sandbox.
  defp vapid_child do
    if Application.get_env(:daily_output, :ensure_vapid, true) do
      [DailyOutput.Vapid]
    else
      []
    end
  end

  defp reminders_child do
    if Application.get_env(:daily_output, :start_reminders, true) do
      [DailyOutput.Reminders]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DailyOutputWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A release migrates on every start, `bin/server` or plain `bin/daily_output start`.
  defp skip_migrations?(), do: System.get_env("RELEASE_NAME") == nil
end
