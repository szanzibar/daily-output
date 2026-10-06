defmodule DailyOutputWeb.ConversationLive do
  @moduledoc """
  One page for a conversation: chat, auto-end, and results.

  `advance/1` reads the saved conversation and starts whatever AI calls it needs next. It
  runs after mount and after every call lands, so a refresh resumes where the last page
  stopped. `Today` saves every result, so a landed call just reloads the activity.
  """
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Activities, Clock, Stats, Today}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Activities.get!(id)

    socket =
      assign(socket,
        page_title: gettext("Conversation"),
        activity: activity,
        today?: activity.date == Clock.today(),
        running: MapSet.new(),
        failed: MapSet.new()
      )

    {:ok, if(connected?(socket), do: advance(socket), else: socket)}
  end

  @impl true
  def handle_event("send", %{"message" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        Activities.add_message(socket.assigns.activity, "user", text)
        {:noreply, socket |> reload() |> advance()}
    end
  end

  def handle_event("retry", _params, socket) do
    {:noreply, socket |> assign(failed: MapSet.new()) |> advance()}
  end

  def handle_event("track_time", %{"section" => section, "seconds" => seconds}, socket) do
    Stats.track(section, seconds)
    {:noreply, socket}
  end

  @impl true
  def handle_async(call, result, socket) do
    socket = update(socket, :running, &MapSet.delete(&1, call))

    case result do
      {:ok, {:ok, _}} -> {:noreply, socket |> reload() |> advance()}
      _ -> {:noreply, update(socket, :failed, &MapSet.put(&1, call))}
    end
  end

  defp reload(socket), do: assign(socket, activity: Activities.get!(socket.assigns.activity.id))

  defp advance(%{assigns: %{activity: %{completed_at: nil} = activity}} = socket) do
    socket =
      for %{role: "user", feedback: nil} = message <- activity.messages, reduce: socket do
        socket -> run(socket, {:correct, message.id}, fn -> Today.correct_message(message) end)
      end

    correcting? = Enum.any?(socket.assigns.running, &match?({:correct, _}, &1))

    cond do
      is_nil(activity.prompt) ->
        run(socket, :prepare, fn -> Today.prepare(activity) end)

      your_message_last?(activity) ->
        run(socket, :reply, fn -> Today.reply(activity) end)

      Today.conversation_over?(activity) and not correcting? ->
        run(socket, :finish, fn -> Today.finish(activity) end)

      true ->
        socket
    end
  end

  defp advance(socket), do: socket

  # One of each call at a time, and a failed one waits for its retry.
  defp run(socket, call, fun) do
    if call in socket.assigns.running or call in socket.assigns.failed do
      socket
    else
      socket |> update(:running, &MapSet.put(&1, call)) |> start_async(call, fun)
    end
  end

  defp your_message_last?(activity), do: match?(%{role: "user"}, List.last(activity.messages))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto space-y-4">
      <div
        :if={is_nil(@activity.completed_at)}
        id="conversation-time-tracker"
        phx-hook="TimeTracker"
        data-section="conversation"
        class="hidden"
      >
      </div>

      <.activity_header title={gettext("Conversation")} activity={@activity} today={@today?} />
      <.focus_banner focus={@activity.focus} />

      <%= if is_nil(@activity.prompt) do %>
        <.preparing
          failed={:prepare in @failed}
          message={gettext("Picking today's focus and writing your opener")}
        />
      <% else %>
        <.chat_log
          opener={@activity.prompt}
          messages={@activity.messages}
          checking={for {:correct, id} <- @running, do: id}
          failed={for {:correct, id} <- @failed, do: id}
        />

        <div :if={:reply in @running} id="partner-typing" class="chat-bubble-row chat-ai">
          <div class="chat-role">{gettext("Partner")}</div>
          <div class="chat-bubble chat-bubble-ai">
            <span class="chat-mini-blocks" aria-label={gettext("Partner is typing")}>
              <span></span><span></span><span></span>
            </span>
          </div>
        </div>
        <.ai_error
          :if={:reply in @failed}
          id="reply-error"
          message={gettext("Your partner didn't answer.")}
        />

        <form
          :if={
            is_nil(@activity.completed_at) and not your_message_last?(@activity) and
              not Today.conversation_over?(@activity)
          }
          id="chat-form"
          phx-submit="send"
          class="flex items-end gap-2"
        >
          <textarea
            id="chat-input"
            name="message"
            rows="1"
            phx-hook="AutoExpand"
            data-persist-key={"chat-#{@activity.id}"}
            phx-mounted={JS.focus()}
            placeholder={gettext("Write a message...")}
            class="chat-input flex-1"
          ></textarea>
          <button
            type="submit"
            class="brutal-btn px-5 py-3 block-blue text-lg shrink-0"
            aria-label={gettext("Send")}
          >
            &rarr;
          </button>
        </form>

        <div :if={:finish in @running} id="finish-loading">
          <.retro_loader message={gettext("Wrapping up your conversation")} />
        </div>
        <.ai_error
          :if={:finish in @failed}
          id="finish-error"
          message={gettext("Couldn't wrap up the conversation.")}
        />

        <div :if={@activity.completed_at} id="results" class="space-y-4 pt-2">
          <hr class="brutal-hr" />
          <.focus_result_box result={@activity.feedback["focus_result"]} />
          <.improvement_panel improvement={@activity.feedback["improvement"]} />
          <.results_nav today={@today?} />
        </div>
      <% end %>
    </div>
    """
  end
end
