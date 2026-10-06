defmodule DailyOutputWeb.AboutLive do
  use DailyOutputWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("About"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto space-y-6">
      <h1 class="text-3xl font-black uppercase tracking-tight">
        {gettext("About DailyOutput")}
      </h1>

      <div class="border-4 border-ink p-4 block-yellow font-mono">
        <p class="text-lg font-bold uppercase">
          {gettext("Practice your language every day. The app plans it, you show up.")}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-blue font-mono space-y-2">
        <h2 class="text-xl font-black uppercase">{gettext("Why")}</h2>
        <p>
          {gettext(
            "Speaking and writing every day is what makes a language stick. There's nothing to set up or pick, so nothing stands between you and practice."
          )}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-pink font-mono space-y-3">
        <h2 class="text-xl font-black uppercase">{gettext("Your day")}</h2>
        <ol class="space-y-2 list-decimal list-inside">
          <li class="font-bold">
            {gettext("A short conversation or a journal entry. The app picks which.")}
          </li>
          <li class="font-bold">
            {gettext("One grammar point to focus on, picked from your own mistakes.")}
          </li>
          <li class="font-bold">{gettext("Corrections on everything you write.")}</li>
          <li class="font-bold">{gettext("Flashcards made from your mistakes.")}</li>
        </ol>
        <p>
          {gettext(
            "Done? The bonus round does the other activity and banks a streak freeze, which saves your streak on a day you miss."
          )}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-green font-mono space-y-2">
        <h2 class="text-xl font-black uppercase">{gettext("Built with")}</h2>
        <p>
          {gettext("Phoenix LiveView and SQLite, with AI from GPT-6.1 Sol or GPT-6 Luna.")}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-orange font-mono space-y-2">
        <h2 class="text-xl font-black uppercase">{gettext("Open source")}</h2>
        <p>
          {gettext("This project is open source. Contributions welcome.")}
        </p>
      </div>
    </div>
    """
  end
end
