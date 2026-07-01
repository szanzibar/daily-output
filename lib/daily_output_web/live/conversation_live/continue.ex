defmodule DailyOutputWeb.ConversationLive.Continue do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Conversations, Settings, AI, FocusTopics, Flashcards}
  alias DailyOutputWeb.Celebration

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    original = Conversations.get_conversation!(id)
    config = Settings.get_config()

    # Continuing a COMPLETED conversation (one with feedback) forks it into a fresh copy so
    # the earned corrections carry over. That create MUST happen exactly once — only on the
    # WebSocket connect — and then we redirect to the fork, which has no feedback and so
    # won't fork again. Doing the create unguarded in mount duplicated the conversation on
    # the dead render, the connect, AND every refresh (LiveView mounts twice per load).
    if original.feedback && connected?(socket) do
      {:ok, fork} = fork_conversation(original)
      {:ok, push_navigate(socket, to: ~p"/conversations/#{fork.id}/continue")}
    else
      # The real continue (no feedback), or the dead render of a soon-to-be-forked
      # conversation (the connect above will fork + redirect). Never create anything here.
      messages = original.messages

      socket =
        assign(socket,
          page_title: gettext("Continue Conversation"),
          config: config,
          conversation: original,
          messages: messages,
          focus_topic_text:
            if original.focus_topic_id do
              FocusTopics.get_topic!(original.focus_topic_id).text
            end,
          input: "",
          ai_loading: false,
          correcting_ids: MapSet.new(),
          feedback: nil,
          feedback_loading: false,
          improvement: nil,
          error: nil
        )

      socket =
        cond do
          not connected?(socket) ->
            socket

          match?(%{role: "user"}, List.last(messages)) ->
            last = List.last(messages)
            send(self(), :request_ai_reply)
            socket = assign(socket, ai_loading: true)

            # A conversation the user opened by typing the first message arrives here with
            # that message saved but not yet corrected: the New wizard seeds it, and the
            # "send" handler that fires the per-message correction on every later turn never
            # ran for it. Correct it now (if it has no feedback yet) so the opening turn gets
            # the same inline corrections as the rest of the chat.
            if is_nil(last.feedback) do
              start_message_correction(socket, last, Enum.drop(messages, -1))
              update(socket, :correcting_ids, &MapSet.put(&1, last.id))
            else
              socket
            end

          messages == [] and original.topic ->
            send(self(), :request_ai_opener)
            assign(socket, ai_loading: true)

          true ->
            socket
        end

      {:ok, socket}
    end
  end

  # Fork a completed conversation into a fresh one, copying every message (including its
  # per-message corrections) so the fork keeps the feedback already earned. Called exactly
  # once per continue (guarded by connected?/redirect in mount/3).
  defp fork_conversation(original) do
    {:ok, fork} =
      Conversations.create_conversation(%{
        topic: original.topic,
        language: original.language,
        focus_topic_id: original.focus_topic_id
      })

    Enum.each(original.messages, fn msg ->
      {:ok, _} = Conversations.copy_message(fork, msg)
    end)

    {:ok, fork}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation
      prior = socket.assigns.messages

      case Conversations.add_message(conversation, %{role: "user", body: message}) do
        {:ok, msg} ->
          messages = prior ++ [msg]

          socket =
            socket
            |> assign(messages: messages, input: "", ai_loading: true)
            |> update(:correcting_ids, &MapSet.put(&1, msg.id))

          # The partner reply and the per-message correction run in parallel: the reply
          # keeps the chat flowing while corrections land on the just-sent bubble.
          start_partner_reply(socket, messages)
          start_message_correction(socket, msg, prior)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save message."))}
      end
    end
  end

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    DailyOutput.Stats.track(section, seconds)
    {:noreply, socket}
  end

  def handle_event("complete", _params, socket) do
    conversation = socket.assigns.conversation
    config = socket.assigns.config
    focus_topic_text = socket.assigns.focus_topic_text

    # Messages were already corrected inline as they were sent, so completion does NOT
    # re-correct: it runs one end-of-conversation review (focus check + future focus areas),
    # grounded in the corrections each message already carries.
    transcript =
      Enum.map(socket.assigns.messages, &%{role: &1.role, body: &1.body, feedback: &1.feedback})

    # The "did you stop repeating mistakes?" axis is computed deterministically here and
    # stored for the score panel.
    improvement = Conversations.mistake_analysis(socket.assigns.messages)

    socket =
      assign(socket, conversation: conversation, feedback_loading: true, improvement: improvement)

    pid = self()

    Task.start(fn ->
      result =
        AI.assess_conversation(transcript,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || "",
          focus_topic: focus_topic_text
        )

      send(pid, {:feedback_loaded, result})
    end)

    # Build flashcards from the whole conversation's corrections in ONE call (best-effort,
    # background) — cheaper than the per-message generation it replaces.
    messages = socket.assigns.messages
    Task.start(fn -> Flashcards.ingest_conversation(conversation.id, messages) end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:request_ai_reply, socket) do
    start_partner_reply(socket, socket.assigns.messages)
    {:noreply, socket}
  end

  def handle_info(:request_ai_opener, socket) do
    config = socket.assigns.config
    topic = socket.assigns.conversation.topic
    pid = self()

    Task.start(fn ->
      result =
        AI.conversation_open(topic,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || ""
        )

      send(pid, {:ai_response, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:ai_response, {:ok, text}}, socket) do
    case Conversations.add_message(socket.assigns.conversation, %{role: "assistant", body: text}) do
      {:ok, msg} ->
        {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], ai_loading: false)}

      {:error, _} ->
        {:noreply, assign(socket, ai_loading: false, error: gettext("Could not save response."))}
    end
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       ai_loading: false,
       error: gettext("AI error: %{reason}", reason: inspect(reason))
     )}
  end

  # A per-message correction came back. Corrections are best-effort: on success we update
  # just that bubble; on failure we simply drop the "checking" state without disrupting chat.
  def handle_info({:message_corrected, msg_id, {:ok, feedback}}, socket) do
    socket = update(socket, :correcting_ids, &MapSet.delete(&1, msg_id))

    case Conversations.save_message_feedback(msg_id, feedback) do
      {:ok, updated} ->
        # Flashcards are no longer built here per message — they're generated once from the
        # whole conversation at completion (see the "complete" handler).
        messages =
          Enum.map(socket.assigns.messages, fn m -> if m.id == msg_id, do: updated, else: m end)

        {:noreply, assign(socket, messages: messages)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:message_corrected, msg_id, {:error, _reason}}, socket) do
    {:noreply, update(socket, :correcting_ids, &MapSet.delete(&1, msg_id))}
  end

  def handle_info({:feedback_loaded, {:ok, feedback}}, socket) do
    # Merge in the deterministic improvement signal computed at completion (the AI only
    # narrates it); normalize_feedback preserves the "improvement" map for the score panel.
    feedback = Map.put(feedback, "improvement", socket.assigns.improvement)

    case Conversations.save_feedback(socket.assigns.conversation, feedback) do
      {:ok, conversation} ->
        if should_complete_conversation?(conversation) do
          case Conversations.complete_conversation(conversation) do
            {:ok, completed_conversation} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Feedback received!"))
               |> push_navigate(to: completion_path(completed_conversation.id))}

            {:error, _changeset} ->
              {:noreply,
               assign(socket,
                 feedback_loading: false,
                 error: gettext("Could not complete conversation.")
               )}
          end
        else
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Focus topic not used yet. Continue and resubmit to complete the day.")
           )
           |> push_navigate(to: ~p"/conversations/#{conversation.id}")}
        end

      {:error, _} ->
        {:noreply,
         assign(socket,
           feedback_loading: false,
           error: gettext("Could not save feedback.")
         )}
    end
  end

  def handle_info({:feedback_loaded, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: gettext("Could not load feedback: %{reason}", reason: inspect(reason))
     )}
  end

  # The completed conversation's show page, celebrating a finished day or streak
  # milestone via the `?celebrate=` token the client turns into confetti.
  defp completion_path(conversation_id) do
    challenge = FocusTopics.daily_challenge_status()
    streak = FocusTopics.streak_info()

    case Celebration.after_completion(challenge.all_done, streak.count) do
      nil -> ~p"/conversations/#{conversation_id}"
      token -> ~p"/conversations/#{conversation_id}?#{[celebrate: token]}"
    end
  end

  defp should_complete_conversation?(conversation) do
    if is_nil(conversation.focus_topic_id) do
      true
    else
      case conversation.feedback do
        %{"focus_result" => %{} = focus_result} ->
          Map.get(focus_result, "used") == true

        _ ->
          false
      end
    end
  end

  defp start_partner_reply(socket, messages) do
    config = socket.assigns.config
    pid = self()

    Task.start(fn ->
      result =
        AI.conversation_respond(messages,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || ""
        )

      send(pid, {:ai_response, result})
    end)

    :ok
  end

  # Proofreads the just-sent message. `prior` (the turns before it, including the partner
  # message being answered) is passed as context so the model judges it in context.
  defp start_message_correction(socket, msg, prior) do
    config = socket.assigns.config
    pid = self()
    context_messages = Enum.map(prior, &%{role: &1.role, body: &1.body})

    Task.start(fn ->
      result =
        AI.proofread_message(msg.body,
          target_language: config.target_language || "de",
          native_language: config.native_language || "en",
          language_level: config.language_level || "B2",
          prompt_context: config.prompt_context || "",
          context_messages: context_messages
        )

      send(pid, {:message_corrected, msg.id, result})
    end)

    :ok
  end

  defp user_count(messages) do
    Enum.count(messages, &(&1.role == "user"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-4">
      <%!-- Tracks active time spent in this conversation. --%>
      <div
        id="conversation-time-tracker"
        phx-hook="TimeTracker"
        data-section="conversation"
        class="hidden"
      >
      </div>

      <div :if={@focus_topic_text} class="border-4 border-ink p-3 block-blue">
        <span class="text-xs font-mono uppercase tracking-widest">{gettext("Focus:")}</span>
        <.rich_text text={@focus_topic_text} class="text-sm mt-1" />
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <h1 class="text-2xl sm:text-3xl font-black tracking-tighter uppercase">
          {gettext("Continue Conversation")}
        </h1>
        <div class="flex items-center gap-3">
          <span class={[
            "text-xs font-mono",
            if(user_count(@messages) >= (@config.min_exchanges || 5),
              do: "timer-met",
              else: "text-base-content/60"
            )
          ]}>
            {gettext("%{count}/%{min} exchanges",
              count: user_count(@messages),
              min: @config.min_exchanges || 5
            )}
          </span>
          <button
            :if={user_count(@messages) >= Conversations.warmup_exchanges() && !@feedback_loading}
            phx-click="complete"
            class="brutal-btn px-4 py-2 block-green text-sm"
          >
            {gettext("Done")} &check;
          </button>
        </div>
      </div>

      <hr class="brutal-hr" />

      <.retro_loader :if={@feedback_loading} message={gettext("Your conversation is being reviewed")} />

      <div :if={!@feedback_loading}>
        <.chat_log messages={@messages} correcting_ids={@correcting_ids} />

        <div :if={@ai_loading} class="chat-bubble-row chat-ai mt-3">
          <div class="chat-role">{gettext("Partner")}</div>
          <div class="chat-bubble chat-bubble-ai">
            <span class="chat-mini-blocks" aria-label={gettext("Partner is typing")}>
              <span></span><span></span><span></span>
            </span>
          </div>
        </div>

        <form :if={!@ai_loading} phx-submit="send" class="flex items-end gap-2 mt-3">
          <textarea
            id="chat-input-continue"
            phx-hook="AutoExpand"
            data-persist-key={"chat-#{@conversation.id}"}
            phx-mounted={JS.focus()}
            name="message"
            rows="1"
            placeholder={gettext("Write a message...")}
            class="chat-input flex-1"
          >{@input}</textarea>
          <button type="submit" class="brutal-btn px-6 py-3 block-blue text-lg shrink-0">
            &rarr;
          </button>
        </form>
      </div>

      <p :if={@error} class="text-sm font-mono text-bold-red">{@error}</p>
    </div>
    """
  end
end
