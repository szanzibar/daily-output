defmodule DailyOutputWeb.ConversationComponents do
  @moduledoc """
  Chat bubble components for conversations.
  """
  use Phoenix.Component
  use Gettext, backend: DailyOutputWeb.Gettext

  @doc """
  Renders the full conversation as chat bubbles for the live view. User messages that have
  been proofread show their corrections inline via the AnnotatedText hook (clean messages
  get a "looks good" badge); messages still being checked show a "checking…" indicator.

  `correcting_ids` is a MapSet of message ids whose proofread is still in flight.
  """
  attr :messages, :list, required: true
  attr :correcting_ids, :any, default: nil

  def chat_log(assigns) do
    ~H"""
    <div class="chat-history space-y-3">
      <.chat_entry
        :for={msg <- @messages}
        message={msg}
        correcting={correcting?(@correcting_ids, msg)}
      />
    </div>
    """
  end

  defp correcting?(%MapSet{} = ids, %{id: id}), do: MapSet.member?(ids, id)
  defp correcting?(_, _), do: false

  attr :message, :map, required: true
  attr :correcting, :boolean, default: false

  def chat_entry(assigns) do
    feedback = if assigns.message.role == "user", do: assigns.message.feedback, else: nil
    annotations = (is_map(feedback) && feedback["annotations"]) || []

    assigns =
      assign(assigns,
        feedback: feedback,
        has_corrections: annotations != [],
        annotations_json: Jason.encode!(annotations)
      )

    ~H"""
    <%= cond do %>
      <% @message.role == "assistant" -> %>
        <div class="chat-bubble-row chat-ai">
          <div class="chat-role">{gettext("Partner")}</div>
          <div class="chat-bubble chat-bubble-ai">{@message.body}</div>
        </div>
      <% is_map(@feedback) -> %>
        <div class="chat-bubble-row chat-feedback-row">
          <div class="chat-role" style="text-align:right">{gettext("You")}</div>
          <div class="chat-bubble-user-feedback">
            <div
              id={"annotated-msg-#{@message.id}"}
              phx-hook="AnnotatedText"
              class="annotated-text"
              data-annotated-text={@feedback["annotated_text"]}
              data-annotations={@annotations_json}
            >
            </div>
            <div :if={!@has_corrections} class="chat-perfect">✓ {gettext("Looks good")}</div>
          </div>
        </div>
      <% true -> %>
        <div class="chat-bubble-row chat-user">
          <div class="chat-role" style="text-align:right">{gettext("You")}</div>
          <div class="chat-bubble chat-bubble-user">{@message.body}</div>
          <div :if={@correcting} class="chat-checking">
            {gettext("checking")}
            <span class="chat-mini-blocks"><span></span><span></span><span></span></span>
          </div>
        </div>
    <% end %>
    """
  end

  @doc """
  The "did you stop repeating mistakes within this conversation?" score panel.

  Renders the deterministic improvement signal (`feedback["improvement"]`): the error-rate
  trend early→late and which mistake categories were resolved vs. still repeating. Pairs
  with `focus_result_box` for the two-axis score.
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
    <div class="border-4 border-ink p-5 mt-6">
      <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
        <span class="inline-block w-3 h-3 block-green"></span>
        {gettext("Progress this conversation")}
      </h2>

      <div
        :if={!is_nil(@early) or !is_nil(@late)}
        class="flex items-center gap-2 mb-3 font-mono text-sm"
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
end
