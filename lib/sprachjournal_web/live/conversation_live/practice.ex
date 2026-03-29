defmodule SprachjournalWeb.ConversationLive.Practice do
  use SprachjournalWeb, :live_view

  alias Sprachjournal.Conversations
  alias Sprachjournal.Practice

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    conversation = Conversations.get_conversation!(id)
    messages = conversation.messages

    corrected_texts =
      Practice.extract_conversation_texts(
        conversation.feedback && conversation.feedback["annotated_text"]
      )

    segments = build_segments(messages, corrected_texts)

    # Find first user segment
    first_user_idx =
      Enum.find_index(segments, &(&1.type == :user)) || 0

    {:ok,
     assign(socket,
       page_title: "Üben — Gespräch",
       conversation: conversation,
       segments: segments,
       current_idx: first_user_idx,
       typed: "",
       result: compare_current(segments, first_user_idx, ""),
       all_done: false
     )}
  end

  defp build_segments(messages, corrected_texts) do
    {segments, _ui} =
      Enum.reduce(messages, {[], 0}, fn msg, {segs, ui} ->
        if msg.role == "user" do
          target = Enum.at(corrected_texts, ui, msg.body)
          {segs ++ [%{type: :user, body: msg.body, target: target}], ui + 1}
        else
          {segs ++ [%{type: :ai, body: msg.body}], ui}
        end
      end)

    segments
  end

  defp compare_current(segments, idx, typed) do
    case Enum.at(segments, idx) do
      %{type: :user, target: target} -> Practice.compare_chars(typed, target)
      _ -> %{compared: [], remaining: "", progress: 0, total: 0, completed: true}
    end
  end

  defp next_user_idx(segments, from_idx) do
    segments
    |> Enum.with_index()
    |> Enum.find_value(fn {seg, i} ->
      if i > from_idx and seg.type == :user, do: i
    end)
  end

  defp total_user_segments(segments), do: Enum.count(segments, &(&1.type == :user))

  defp completed_user_count(segments, current_idx) do
    segments
    |> Enum.with_index()
    |> Enum.count(fn {seg, i} -> seg.type == :user and i < current_idx end)
  end

  @impl true
  def handle_event("typing", %{"practice" => %{"text" => typed}}, socket) do
    result = compare_current(socket.assigns.segments, socket.assigns.current_idx, typed)
    socket = assign(socket, typed: typed, result: result)

    if result.completed do
      case next_user_idx(socket.assigns.segments, socket.assigns.current_idx) do
        nil ->
          if is_nil(socket.assigns.conversation.practiced_at) do
            {:ok, convo} = Practice.mark_conversation_practiced(socket.assigns.conversation)
            {:noreply, assign(socket, conversation: convo, all_done: true)}
          else
            {:noreply, assign(socket, all_done: true)}
          end

        next_idx ->
          {:noreply,
           assign(socket,
             current_idx: next_idx,
             typed: "",
             result: compare_current(socket.assigns.segments, next_idx, "")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-3xl sm:text-4xl font-black tracking-tighter uppercase">
          Üben — Gespräch
        </h1>
        <span class="text-sm font-mono text-base-content/60">
          {completed_user_count(@segments, @current_idx) + if(@result.completed, do: 1, else: 0)}/{total_user_segments(@segments)} Nachrichten
        </span>
      </div>

      <hr class="brutal-hr" />

      <%!-- Progress bar --%>
      <div class="border-3 border-ink h-4 bg-base-200">
        <% total_chars = @segments |> Enum.filter(&(&1.type == :user)) |> Enum.map(&String.length(&1.target)) |> Enum.sum() %>
        <% done_segs = @segments |> Enum.with_index() |> Enum.filter(fn {s, i} -> s.type == :user and i < @current_idx end) %>
        <% done_chars = done_segs |> Enum.map(fn {s, _} -> String.length(s.target) end) |> Enum.sum() %>
        <% pct = if total_chars > 0, do: round((done_chars + @result.progress) / total_chars * 100), else: 0 %>
        <div
          class={["h-full transition-all", if(@all_done, do: "block-green", else: "block-blue")]}
          style={"width: #{pct}%"}
        />
      </div>

      <%!-- Completed --%>
      <div :if={@all_done} class="border-4 border-ink p-6 block-green text-center">
        <h2 class="text-3xl font-black uppercase mb-2">Geschafft!</h2>
        <p class="text-sm opacity-80">Alle Nachrichten fehlerfrei abgeschrieben.</p>
        <.link
          navigate={~p"/conversations/#{@conversation.id}"}
          class="brutal-btn inline-block px-6 py-3 bg-ink text-paper text-lg no-underline mt-4"
        >
          Zurück
        </.link>
      </div>

      <%!-- Conversation with practice --%>
      <div :if={!@all_done} class="space-y-3">
        <%= for {seg, idx} <- Enum.with_index(@segments) do %>
          <%!-- Past messages as context --%>
          <%= if idx < @current_idx do %>
            <div class={["chat-bubble-row", if(seg.type == :user, do: "chat-user", else: "chat-ai")]}>
              <div class="chat-role">{if seg.type == :user, do: "Du", else: "Partner"}</div>
              <div class={["chat-bubble", if(seg.type == :user, do: "chat-bubble-user", else: "chat-bubble-ai")]}>
                {if seg.type == :user, do: seg.target, else: seg.body}
              </div>
            </div>
          <% end %>

          <%!-- AI message right at current_idx (show as context above practice) --%>
          <%= if idx == @current_idx and seg.type == :ai do %>
            <div class="chat-bubble-row chat-ai">
              <div class="chat-role">Partner</div>
              <div class="chat-bubble chat-bubble-ai">{seg.body}</div>
            </div>
          <% end %>

          <%!-- Current user message to practice --%>
          <%= if idx == @current_idx and seg.type == :user do %>
            <div class="border-4 border-ink p-5">
              <div class="text-xs font-mono uppercase tracking-widest text-base-content/60 mb-3">
                Deine Nachricht abtippen:
              </div>
              <div class="practice-overlay-container">
                <div class="practice-ghost" aria-hidden="true">
                  <%= for {char, status} <- @result.compared do %><span class={if status == :correct, do: "practice-correct", else: "practice-wrong"}>{char}</span><% end %><span class="practice-cursor">|</span><span class="practice-remaining">{@result.remaining}</span>
                </div>
                <.form for={%{}} phx-change="typing" class="practice-form">
                  <textarea
                    name="practice[text]"
                    class="practice-textarea"
                    phx-mounted={JS.focus()}
                    spellcheck="false"
                    autocomplete="off"
                    autocorrect="off"
                    autocapitalize="off"
                  >{@typed}</textarea>
                </.form>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>

      <.link
        navigate={~p"/conversations/#{@conversation.id}"}
        class="brutal-btn inline-block px-4 py-2 bg-base-200 no-underline text-sm"
      >
        &larr; Zurück
      </.link>
    </div>
    """
  end
end
