defmodule DailyOutput.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DailyOutputWeb.Telemetry,
        DailyOutput.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:daily_output, :ecto_repos), skip: skip_migrations?()}
      ] ++
        vapid_child() ++
        [
          {DNSCluster, query: Application.get_env(:daily_output, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: DailyOutput.PubSub},
          # Start to serve requests, typically the last entry
          DailyOutputWeb.Endpoint
        ] ++ reminders_child() ++ backfill_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DailyOutput.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Generates/loads the VAPID keypair right after migrations, before we serve
  # requests. Disabled in tests, which assert on the unconfigured state.
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

  # TEMPORARY: seeds flashcards from existing corrections on first boot (no-op once the
  # deck is non-empty). Runs in a background Task so it never blocks startup. Delete this
  # together with DailyOutput.Flashcards.Backfill once it has run in your environment.
  defp backfill_child do
    if Application.get_env(:daily_output, :auto_backfill_flashcards, true) do
      [
        Supervisor.child_spec({Task, &DailyOutput.Flashcards.Backfill.maybe_run/0},
          restart: :temporary
        )
      ]
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

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
