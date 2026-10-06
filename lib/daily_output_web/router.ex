defmodule DailyOutputWeb.Router do
  use DailyOutputWeb, :router

  # Only our own bundles run, so scripts need nothing past 'self'. Styles allow inline for the
  # server-rendered style attributes, and images allow data: for the icon masks.
  @csp "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " <>
         "frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DailyOutputWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  scope "/", DailyOutputWeb do
    pipe_through :browser

    live_session :default,
      layout: {DailyOutputWeb.Layouts, :app},
      on_mount: {DailyOutputWeb.Locale, :set_locale} do
      live "/", TodayLive
      live "/conversation/:id", ConversationLive
      live "/journal/:id", JournalLive
      live "/flashcards", FlashcardLive.Study
      live "/flashcards/manage", FlashcardLive.Manage
      live "/history", HistoryLive
      live "/progress", ProgressLive
      live "/settings", SettingsLive
      live "/about", AboutLive
    end
  end
end
