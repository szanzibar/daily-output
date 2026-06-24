defmodule DailyOutput.Reminders do
  @moduledoc """
  Fires the daily "you haven't practiced yet" push.

  A GenServer ticks once a minute and, when the local time has passed the user's
  reminder time and today's goal isn't done, sends one push (deduped per day). The
  send/skip decision lives in the pure `due?/4` so it can be tested without timers.
  """

  use GenServer
  require Logger

  use Gettext, backend: DailyOutputWeb.Gettext

  alias DailyOutput.{Clock, FocusTopics, Push, Settings}

  @tick :timer.minutes(1)

  # ── Public API ──────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Decides whether a reminder is due, ignoring whether any device is subscribed
  (`maybe_remind/0` gates on that). Pure over its inputs so it's trivially testable.

    * `config` — the settings struct
    * `now_local` — current `DateTime` in the user's timezone
    * `today` — the current logical date
    * `day_done?` — whether today's goal is already met
  """
  def due?(config, now_local, today, day_done?) do
    not day_done? and
      config.last_reminder_on != today and
      Time.compare(DateTime.to_time(now_local), config.reminder_time) != :lt
  end

  @doc "Checks the current state and sends a reminder if one is due. Returns :sent | :skip."
  def maybe_remind do
    config = Settings.get_config()
    day_done? = FocusTopics.daily_challenge_status().all_done

    if Push.configured?() and Push.any?() and due?(config, Clock.now(), Clock.today(), day_done?) do
      Push.send_to_all(notification(config))
      {:ok, saved} = Settings.ensure_config()
      Settings.update_config(saved, %{last_reminder_on: Clock.today()})
      :sent
    else
      :skip
    end
  end

  # ── GenServer ───────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, schedule()}

  @impl true
  def handle_info(:tick, state) do
    try do
      maybe_remind()
    rescue
      error -> Logger.error("Reminder tick failed: #{inspect(error)}")
    end

    {:noreply, schedule(state)}
  end

  defp schedule(state \\ nil) do
    Process.send_after(self(), :tick, @tick)
    state
  end

  defp notification(config) do
    put_locale(config)
    streak = FocusTopics.current_streak()

    body =
      if streak > 0 do
        gettext("Your %{n}-day streak ends soon — one quick entry keeps it alive.", n: streak)
      else
        gettext("You haven't practiced yet today. A few minutes is all it takes.")
      end

    %{title: gettext("Daily Output"), body: body, url: "/"}
  end

  defp put_locale(config) do
    locale = if config.ui_language in ~w(en de), do: config.ui_language, else: "en"
    Gettext.put_locale(DailyOutputWeb.Gettext, locale)
  end
end
