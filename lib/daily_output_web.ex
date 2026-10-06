defmodule DailyOutputWeb do
  @moduledoc """
  The entrypoint for defining your web interface: the router, live views, and components.

  This can be used in your application as:

      use DailyOutputWeb, :live_view
      use DailyOutputWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets images favicon.ico robots.txt manifest.json sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: DailyOutputWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import DailyOutputWeb.CoreComponents
      import DailyOutputWeb.ActivityComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias DailyOutputWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DailyOutputWeb.Endpoint,
        router: DailyOutputWeb.Router,
        statics: DailyOutputWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
