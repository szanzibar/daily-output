defmodule DailyOutputWeb.ActivityComponents do
  @moduledoc """
  What the conversation and journal pages share: the focus banner, the chat, corrections,
  results, and the loading and error states around AI calls.
  """
  use Phoenix.Component
  use Gettext, backend: DailyOutputWeb.Gettext
  use DailyOutputWeb, :verified_routes

  import DailyOutputWeb.CoreComponents, only: [icon: 1, rich_text: 1]

  @doc "An activity's page. A finished one shows its results, so History links here too."
  def activity_path(%{kind: "conversation", id: id}), do: ~p"/conversation/#{id}"
  def activity_path(%{kind: "journal", id: id}), do: ~p"/journal/#{id}"

  attr :title, :string, required: true
  attr :activity, :map, required: true
  attr :today, :boolean, required: true

  def activity_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline justify-between gap-2">
      <h1 class="text-3xl sm:text-4xl font-black tracking-tighter uppercase">{@title}</h1>
      <span :if={!@today} class="text-sm font-mono text-base-content/60">
        {Calendar.strftime(@activity.date, "%d.%m.%Y")}
      </span>
    </div>
    """
  end

  @doc "Today's grammar point: the rule and an example, to use while you write."
  attr :focus, :map, default: nil

  def focus_banner(assigns) do
    ~H"""
    <section :if={@focus["title"]} id="focus-banner" class="border-4 border-ink p-4 block-blue">
      <p class="text-xs font-mono uppercase tracking-widest opacity-80">{gettext("Focus")}</p>
      <p class="text-lg sm:text-xl font-black leading-tight mt-1">{@focus["title"]}</p>
      <.rich_text :if={@focus["body"]} text={@focus["body"]} class="text-sm mt-2" />
    </section>
    """
  end

  @doc "While `Today.prepare/1` writes the focus banner and the opener or prompt."
  attr :failed, :boolean, required: true
  attr :message, :string, required: true

  def preparing(assigns) do
    ~H"""
    <div :if={!@failed} id="prepare-loading"><.retro_loader message={@message} /></div>
    <.ai_error
      :if={@failed}
      id="prepare-error"
      message={gettext("Couldn't get today's session ready.")}
    />
    """
  end

  @doc "The one error state every AI call gets. Retry sends `retry` to the page."
  attr :id, :string, required: true
  attr :message, :string, required: true

  def ai_error(assigns) do
    ~H"""
    <div
      id={@id}
      class="border-4 border-ink block-red p-4 flex flex-wrap items-center justify-between gap-3"
    >
      <p class="font-bold text-sm">{@message}</p>
      <button
        type="button"
        phx-click="retry"
        class="brutal-btn px-4 py-2 text-sm block-yellow inline-flex items-center gap-2"
      >
        <.icon name="hero-arrow-path" class="size-4" /> {gettext("Try again")}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :feedback, :map, required: true

  def annotated_text(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="AnnotatedText"
      phx-update="ignore"
      class="annotated-text"
      data-annotated-text={@feedback["annotated_text"]}
      data-annotations={Jason.encode!(@feedback["annotations"] || [])}
    >
    </div>
    """
  end

  @doc """
  The conversation as chat bubbles, opener first. Your messages show their corrections
  inline once they're back.
  """
  attr :opener, :string, required: true
  attr :messages, :list, required: true
  attr :checking, :list, default: [], doc: "ids of messages being corrected"
  attr :failed, :list, default: [], doc: "ids of messages whose correction failed"

  def chat_log(assigns) do
    ~H"""
    <div id="chat" class="space-y-3">
      <div id="opener" class="chat-bubble-row chat-ai">
        <div class="chat-role">{gettext("Partner")}</div>
        <div class="chat-bubble chat-bubble-ai">{@opener}</div>
      </div>
      <%= for msg <- @messages do %>
        <%= cond do %>
          <% msg.role == "assistant" -> %>
            <div id={"message-#{msg.id}"} class="chat-bubble-row chat-ai">
              <div class="chat-role">{gettext("Partner")}</div>
              <div class="chat-bubble chat-bubble-ai">{msg.body}</div>
            </div>
          <% msg.feedback -> %>
            <div id={"message-#{msg.id}"} class="chat-bubble-row chat-feedback-row">
              <div class="chat-role text-right">{gettext("You")}</div>
              <div class="chat-bubble-user-feedback">
                <.annotated_text id={"correction-#{msg.id}"} feedback={msg.feedback} />
                <div :if={msg.feedback["annotations"] in [nil, []]} class="chat-perfect">
                  ✓ {gettext("Looks good")}
                </div>
              </div>
            </div>
          <% true -> %>
            <div id={"message-#{msg.id}"} class="chat-bubble-row chat-user">
              <div class="chat-role text-right">{gettext("You")}</div>
              <div class="chat-bubble chat-bubble-user">{msg.body}</div>
              <div :if={msg.id in @checking} class="chat-checking">
                {gettext("checking")}
                <span class="chat-mini-blocks"><span></span><span></span><span></span></span>
              </div>
              <div :if={msg.id in @failed} id={"correction-error-#{msg.id}"} class="chat-checking">
                {gettext("Couldn't check this one.")}
                <button type="button" phx-click="retry" class="underline font-black">
                  {gettext("Try again")}
                </button>
              </div>
            </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Did you stop repeating a mistake within this conversation? Renders
  `Activities.mistake_analysis/1`: the error rate early vs. late, and which categories you
  resolved or kept repeating.
  """
  attr :improvement, :map, required: true

  def improvement_panel(assigns) do
    imp = assigns.improvement

    assigns =
      assign(assigns,
        resolved: imp["resolved_categories"] || [],
        repeated: imp["repeated_categories"] || [],
        early: imp["early_rate"],
        late: imp["late_rate"]
      )

    ~H"""
    <div id="improvement" class="border-4 border-ink p-5">
      <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
        <span class="inline-block w-3 h-3 block-green"></span>
        {gettext("Progress this conversation")}
      </h2>

      <div
        :if={!is_nil(@early) or !is_nil(@late)}
        class="flex flex-wrap items-center gap-2 mb-3 font-mono text-sm"
      >
        <span class="uppercase text-xs text-base-content/60">
          {gettext("Errors / 100 words")}
        </span>
        <span class="font-bold">{rate_label(@early)}</span>
        <span>&rarr;</span>
        <span class={["font-bold px-2 py-0.5 border-2 border-ink", trend_class(@early, @late)]}>
          {rate_label(@late)}
        </span>
      </div>

      <div :if={@resolved != []} class="mb-2">
        <p class="text-xs font-mono uppercase text-base-content/60 mb-1">
          {gettext("Stopped repeating")}
        </p>
        <div class="flex flex-wrap gap-1">
          <span
            :for={cat <- @resolved}
            class="px-2 py-0.5 block-green text-xs font-bold border-2 border-ink"
          >
            {category_label(cat)}
          </span>
        </div>
      </div>

      <div :if={@repeated != []}>
        <p class="text-xs font-mono uppercase text-base-content/60 mb-1">
          {gettext("Still working on")}
        </p>
        <div class="flex flex-wrap gap-1">
          <span
            :for={cat <- @repeated}
            class="px-2 py-0.5 block-orange text-xs font-bold border-2 border-ink"
          >
            {category_label(cat)}
          </span>
        </div>
      </div>

      <p
        :if={@resolved == [] and @repeated == [] and is_nil(@early) and is_nil(@late)}
        class="text-sm text-base-content/60"
      >
        {gettext("Not enough data yet — keep chatting!")}
      </p>
    </div>
    """
  end

  defp rate_label(nil), do: "—"
  defp rate_label(rate), do: to_string(rate)

  # Down is good (fewer errors late), up is bad, flat is neutral.
  defp trend_class(early, late) when is_number(early) and is_number(late) do
    cond do
      late < early -> "block-green"
      late > early -> "block-red"
      true -> "block-yellow"
    end
  end

  defp trend_class(_, _), do: "block-yellow"

  defp category_label("gender"), do: gettext("gender")
  defp category_label("case"), do: gettext("case")
  defp category_label("verb"), do: gettext("verb")
  defp category_label("word-order"), do: gettext("word order")
  defp category_label("agreement"), do: gettext("agreement")
  defp category_label("preposition"), do: gettext("preposition")
  defp category_label("spelling"), do: gettext("spelling")
  defp category_label("vocabulary"), do: gettext("vocabulary")
  defp category_label("punctuation"), do: gettext("punctuation")
  defp category_label(_), do: gettext("other")

  @doc "How you did on the focus: used, and used correctly."
  attr :result, :map, required: true

  def focus_result_box(assigns) do
    assigns = assign(assigns, used: assigns.result["used"], correct: assigns.result["correct"])

    ~H"""
    <div
      id="focus-result"
      class={[
        "border-4 border-ink p-5",
        cond do
          @used && @correct -> "block-green"
          @used -> "block-orange"
          true -> "block-red"
        end
      ]}
    >
      <h2 class="text-lg font-black uppercase mb-2">{gettext("Focus Result")}</h2>
      <p class="text-sm font-bold mb-2">
        <%= cond do %>
          <% @used && @correct -> %>
            {gettext("Used correctly!")}
          <% @used -> %>
            {gettext("Attempted — keep practicing!")}
          <% true -> %>
            {gettext("Not used.")}
        <% end %>
      </p>
      <p :if={@result["comment"]} class="text-sm">{@result["comment"]}</p>
    </div>
    """
  end

  @doc "Where a finished activity's page goes next: on through today, or back to History."
  attr :today, :boolean, required: true

  def results_nav(assigns) do
    ~H"""
    <.link
      :if={@today}
      id="continue"
      navigate={~p"/"}
      class="brutal-btn block w-full sm:w-auto sm:inline-block px-8 py-3 text-lg text-center block-green no-underline"
    >
      {gettext("Continue")} &rarr;
    </.link>
    <.link
      :if={!@today}
      id="back-to-history"
      navigate={~p"/history"}
      class="brutal-btn inline-block px-6 py-3 block-yellow no-underline"
    >
      &larr; {gettext("History")}
    </.link>
    """
  end

  @doc "The one loading state every AI call gets: bouncing blocks, what's happening, a bar."
  attr :message, :string, required: true

  def retro_loader(assigns) do
    ~H"""
    <div class="loading-retro border-4 border-ink px-5 py-8 sm:py-10 shadow-[6px_6px_0_var(--color-ink)]">
      <div class="loading-blocks" aria-hidden="true">
        <span class="loading-block block-red"></span>
        <span class="loading-block block-blue"></span>
        <span class="loading-block block-yellow"></span>
        <span class="loading-block block-green"></span>
        <span class="loading-block block-pink"></span>
      </div>
      <p class="text-sm font-mono font-bold text-center tracking-widest uppercase" role="status">
        {@message}<span class="loading-cursor" aria-hidden="true">_</span>
      </p>
      <div class="loading-bar" aria-hidden="true">
        <div class="loading-bar-fill"></div>
      </div>
    </div>
    """
  end
end
