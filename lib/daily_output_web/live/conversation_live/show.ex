defmodule DailyOutputWeb.ConversationLive.Show do
  use DailyOutputWeb, :live_view

  alias DailyOutput.Conversations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    conversation = Conversations.get_conversation!(id)
    messages = conversation.messages
    {version, total} = Conversations.version_info(conversation)
    versions = Conversations.get_versions(conversation)

    focus_mastered =
      if conversation.focus_topic_id do
        topic = DailyOutput.FocusTopics.get_topic!(conversation.focus_topic_id)
        topic.mastered_at != nil
      else
        false
      end

    {:ok,
     assign(socket,
       page_title:
         gettext("Conversation — %{date}",
           date: Calendar.strftime(conversation.inserted_at, "%d.%m.%Y")
         ),
       conversation: conversation,
       messages: messages,
       version: version,
       total_versions: total,
       versions: versions,
       confirm_delete: false,
       focus_pool_texts: DailyOutput.FocusTopics.active_source_texts(),
       focus_mastered: focus_mastered
     )}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false)}
  end

  def handle_event("delete", _params, socket) do
    case Conversations.soft_delete_conversation(socket.assigns.conversation) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Conversation deleted."))
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete."))}
    end
  end

  def handle_event("add_focus_topic", params, socket) do
    alias DailyOutput.{FocusTopics, AI}
    raw_text = params["text"]

    summarized =
      case AI.summarize_focus_topic(raw_text) do
        {:ok, text} -> text
        {:error, _} -> raw_text
      end

    FocusTopics.create_topic(%{
      text: summarized,
      source_text: raw_text,
      source_type: params["source_type"],
      source_id: String.to_integer(params["source_id"])
    })

    {:noreply, assign(socket, focus_pool_texts: FocusTopics.active_source_texts())}
  end

  def handle_event("master_focus_topic", _params, socket) do
    alias DailyOutput.FocusTopics
    convo = socket.assigns.conversation

    if convo.focus_topic_id do
      topic = FocusTopics.get_topic!(convo.focus_topic_id)
      {:ok, _} = FocusTopics.master_topic(topic)

      {:noreply,
       assign(socket,
         focus_mastered: true,
         focus_pool_texts: FocusTopics.active_source_texts()
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("override_focus_result", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Overridden — counts as used."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-1">
            {gettext("Conversation")}
          </p>
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            {Calendar.strftime(@conversation.inserted_at, "%d.%m.%Y")}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-xs font-mono">
          <span :if={@conversation.completed_at} class="px-2 py-1 block-green uppercase">
            {gettext("Done")}
          </span>
          <span :if={is_nil(@conversation.completed_at)} class="px-2 py-1 block-orange uppercase">
            {gettext("Open")}
          </span>
          <span class="text-base-content/60">
            {gettext("%{count} exchanges", count: Enum.count(@messages, &(&1.role == "user")))}
          </span>
        </div>
      </div>

      <%!-- Version nav --%>
      <div :if={@total_versions > 1} class="flex flex-wrap items-center gap-2 text-sm font-mono">
        <span class="font-bold">
          {gettext("v%{version} of %{total}", version: @version, total: @total_versions)}
        </span>
        <%= for {v, idx} <- Enum.with_index(Enum.reverse(@versions), 1) do %>
          <.link
            :if={v.id != @conversation.id}
            navigate={~p"/conversations/#{v.id}"}
            class="brutal-btn px-2 py-1 block-cyan text-xs no-underline"
          >
            v{idx}
          </.link>
          <span :if={v.id == @conversation.id} class="px-2 py-1 border-2 border-ink text-xs font-bold">
            v{idx}
          </span>
        <% end %>
      </div>

      <hr class="brutal-hr" />

      <%!-- Actions --%>
      <div class="flex flex-wrap items-center gap-3">
        <.link
          navigate={~p"/conversations/#{@conversation.id}/continue"}
          class="brutal-btn px-4 py-2 block-pink text-sm no-underline"
        >
          {if @conversation.feedback, do: gettext("New Version"), else: gettext("Continue")}
        </.link>
        <button
          :if={!@confirm_delete}
          phx-click="confirm_delete"
          class="brutal-btn px-4 py-2 block-dark text-sm"
        >
          {gettext("Delete")}
        </button>
        <div :if={@confirm_delete} class="flex items-center gap-2">
          <span class="text-xs font-mono text-bold-red">{gettext("Really delete?")}</span>
          <button phx-click="delete" class="brutal-btn px-3 py-1 block-red text-xs">
            {gettext("Yes")}
          </button>
          <button phx-click="cancel_delete" class="brutal-btn px-3 py-1 bg-base-200 text-xs">
            {gettext("No")}
          </button>
        </div>
      </div>

      <div
        :if={@conversation.topic}
        class="text-sm font-mono text-base-content/60 border-l-4 border-ink pl-3"
      >
        {gettext("Topic:")} {@conversation.topic}
      </div>

      <%!-- Conversation with feedback (unified) or plain chat --%>
      <div :if={@conversation.feedback}>
        <div
          :if={@conversation.feedback["encouragement"]}
          class="border-4 border-ink p-5 block-yellow mb-6"
        >
          <p class="font-bold text-base">{@conversation.feedback["encouragement"]}</p>
        </div>

        <div class="border-4 border-ink p-4">
          <h2 class="text-lg font-black uppercase mb-4 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-red"></span> {gettext(
              "Conversation with Corrections"
            )}
          </h2>
          <.chat_feedback messages={@messages} feedback={@conversation.feedback} />
        </div>

        <%!-- Focus Result --%>
        <.focus_result_box
          :if={@conversation.feedback["focus_result"]}
          result={@conversation.feedback["focus_result"]}
          focus_mastered={@focus_mastered}
        />

        <div
          :if={(@conversation.feedback["commentary"] || []) != []}
          class="border-4 border-ink p-5 mt-6"
        >
          <h2 class="text-lg font-black uppercase mb-3 flex items-center gap-2">
            <span class="inline-block w-3 h-3 block-blue"></span> {gettext("Tips")}
          </h2>
          <div
            :for={item <- @conversation.feedback["commentary"] || []}
            class="mb-3 last:mb-0 flex items-start gap-2"
          >
            <div class="flex-1">
              <span class="text-xs font-mono uppercase px-2 py-0.5 border-2 border-ink mr-2">
                {item["type"]}
              </span>
              <span class="text-sm">{item["text"]}</span>
            </div>
            <%= if item["text"] in @focus_pool_texts do %>
              <span class="brutal-btn px-2 py-0.5 block-green text-xs shrink-0">✓</span>
            <% else %>
              <button
                phx-click="add_focus_topic"
                phx-value-text={item["text"]}
                phx-value-source_type="conversation"
                phx-value-source_id={@conversation.id}
                class="brutal-btn px-2 py-0.5 block-blue text-xs shrink-0 phx-click-loading:opacity-50 phx-click-loading:animate-pulse"
              >
                +
              </button>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Plain chat (no feedback yet) --%>
      <div :if={is_nil(@conversation.feedback)} class="border-4 border-ink p-4">
        <.chat_history messages={@messages} />
      </div>

      <.link
        navigate={~p"/"}
        class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
      >
        &larr; {gettext("Back")}
      </.link>
    </div>
    """
  end
end
