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

    live "/", HomeLive
    live "/entries/new", EntryLive.New
    live "/entries/:id", EntryLive.Show
    live "/entries/:id/edit", EntryLive.Edit
    live "/settings", SettingsLive
  end
end
