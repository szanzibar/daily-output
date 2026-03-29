defmodule SprachjournalWeb.Router do
  use SprachjournalWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SprachjournalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", SprachjournalWeb do
    pipe_through :browser

    live_session :default, layout: {SprachjournalWeb.Layouts, :app} do
      live "/", HomeLive
      live "/entries/new", EntryLive.New
      live "/entries/:id", EntryLive.Show
      live "/entries/:id/edit", EntryLive.Edit
      live "/entries/:id/practice", EntryLive.Practice
      live "/conversations/new", ConversationLive.New
      live "/conversations/:id", ConversationLive.Show
      live "/conversations/:id/continue", ConversationLive.Continue
      live "/conversations/:id/practice", ConversationLive.Practice
      live "/settings", SettingsLive
    end
  end
end
