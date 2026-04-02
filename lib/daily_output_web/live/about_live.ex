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
          {gettext("A daily language practice journal with AI feedback.")}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-blue text-white font-mono space-y-2">
        <h2 class="text-xl font-black uppercase">{gettext("Purpose")}</h2>
        <p>
          {gettext(
            "Generate language output every day as a habit. Get instant AI feedback on your writing and conversations. The only way to get better is to practice."
          )}
        </p>
      </div>

      <div class="border-4 border-ink p-4 block-pink font-mono space-y-3">
        <h2 class="text-xl font-black uppercase">{gettext("Features")}</h2>
        <ul class="space-y-1 list-none">
          <li class="font-bold">{gettext("Timed writing entries")}</li>
          <li class="font-bold">{gettext("AI conversations")}</li>
          <li class="font-bold">{gettext("Corrections & tips")}</li>
          <li class="font-bold">{gettext("Focus topics for targeted practice")}</li>
          <li class="font-bold">{gettext("Streak tracking")}</li>
        </ul>
      </div>

      <div class="border-4 border-ink p-4 block-green font-mono space-y-2">
        <h2 class="text-xl font-black uppercase">{gettext("Built with")}</h2>
        <p>
          {gettext("Phoenix LiveView, powered by Claude AI.")}
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
