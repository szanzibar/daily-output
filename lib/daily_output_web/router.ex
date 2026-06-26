defmodule DailyOutputWeb.Router do
  use DailyOutputWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DailyOutputWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", DailyOutputWeb do
    pipe_through :browser

    live_session :default,
      layout: {DailyOutputWeb.Layouts, :app},
      on_mount: {DailyOutputWeb.Locale, :set_locale} do
      live "/", HomeLive
      live "/entries/new", EntryLive.New
      live "/entries/:id", EntryLive.Show
      live "/entries/:id/edit", EntryLive.Edit
      live "/conversations/new", ConversationLive.New
      live "/conversations/:id", ConversationLive.Show
      live "/conversations/:id/continue", ConversationLive.Continue
      live "/flashcards", FlashcardLive.Study
      live "/flashcards/manage", FlashcardLive.Manage
      live "/focus", FocusTopicsLive
      live "/progress", ProgressLive
      live "/settings", SettingsLive
      live "/about", AboutLive
    end
  end
end
