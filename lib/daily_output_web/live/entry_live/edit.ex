defmodule DailyOutputWeb.EntryLive.Edit do
  use DailyOutputWeb, :live_view

  alias DailyOutput.{Journal, Settings, AI}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    entry = Journal.get_entry!(id)
    config = Settings.get_config()

    {:ok,
     assign(socket,
       page_title:
         gettext("Edit — %{date}", date: Calendar.strftime(entry.inserted_at, "%d.%m.%Y")),
       config: config,
       entry: entry,
       body: entry.body || "",
       phase: :writing,
       feedback: nil,
       feedback_loading: false,
       error: nil
     )}
  end

  @impl true
  def handle_event("update_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, body: body)}
  end

  def handle_event("save", _params, socket) do
    body = socket.assigns.body
    entry = socket.assigns.entry

    if String.trim(body) == "" do
      {:noreply, put_flash(socket, :error, gettext("Write something first!"))}
    else
      # If entry already has feedback, save as a new version (don't overwrite old feedback)
      # If no feedback yet, it's a draft — true edit is fine
      result =
        if entry.feedback do
          Journal.create_entry(%{
            body: body,
            prompt: entry.prompt,
            language: entry.language,
            duration: entry.duration,
            focus_topic_id: entry.focus_topic_id
          })
        else
          Journal.update_entry(entry, %{body: body})
        end

      case result do
        {:ok, saved_entry} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Saved."))
           |> push_navigate(to: ~p"/entries/#{saved_entry.id}")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save."))}
      end
    end
  end

  def handle_event("resubmit", _params, socket) do
    body = socket.assigns.body
    config = socket.assigns.config
    entry = socket.assigns.entry

    if String.trim(body) == "" do
      {:noreply, put_flash(socket, :error, gettext("Write something first!"))}
    else
      # Create a NEW entry (new version) instead of overwriting the old one
      attrs = %{
        body: body,
        prompt: entry.prompt,
        language: entry.language,
        duration: entry.duration,
        focus_topic_id: entry.focus_topic_id
      }

      case Journal.create_entry(attrs) do
        {:ok, new_entry} ->
          new_entry = Journal.complete_entry(new_entry) |> elem(1)

          pid = self()

          Task.start(fn ->
            focus_text =
              if entry.focus_topic_id do
                DailyOutput.FocusTopics.get_topic!(entry.focus_topic_id).text
              end

            result =
              AI.proofread(body,
                target_language: config.target_language || "de",
                native_language: config.native_language || "en",
                language_level: config.language_level || "B2",
                prompt_context: config.prompt_context || "",
                focus_topic: focus_text
              )

            send(pid, {:feedback_loaded, result, new_entry})
          end)

          {:noreply, assign(socket, entry: new_entry, phase: :feedback, feedback_loading: true)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save."))}
      end
    end
  end

  @impl true
  def handle_info({:feedback_loaded, {:ok, feedback}, entry}, socket) do
    case Journal.save_feedback(entry, feedback) do
      {:ok, entry} ->
        {:noreply, push_navigate(socket, to: ~p"/entries/#{entry.id}")}

      {:error, _} ->
        {:noreply, assign(socket, feedback: feedback, feedback_loading: false)}
    end
  end

  def handle_info({:feedback_loaded, {:error, :api_key_not_set}, _entry}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error:
         gettext("ANTHROPIC_API_KEY not set. Add it to the .env file and restart the server.")
     )}
  end

  def handle_info({:feedback_loaded, {:error, reason}, _entry}, socket) do
    {:noreply,
     assign(socket,
       feedback_loading: false,
       error: gettext("Could not load feedback: %{reason}", reason: inspect(reason))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <%!-- PHASE: Writing/Editing --%>
      <div :if={@phase == :writing}>
        <.editor id={"editor-#{@entry.id}"} body={@body} prompt={@entry.prompt} error={@error}>
          <:header>
            <h1 class="text-3xl sm:text-4xl font-black tracking-tighter uppercase">
              {gettext("Edit")}
            </h1>
            <span class="text-sm font-mono text-base-content/60">
              {Calendar.strftime(@entry.inserted_at, "%d.%m.%Y")}
            </span>
          </:header>
          <:actions>
            <.link
              navigate={~p"/entries/#{@entry.id}"}
              class="brutal-btn px-4 py-2 block-dark text-sm no-underline"
            >
              {gettext("Cancel")}
            </.link>
            <button phx-click="save" class="brutal-btn px-4 py-2 block-cyan text-sm">
              {gettext("Save")}
            </button>
            <button phx-click="resubmit" class="brutal-btn px-6 py-3 block-green text-lg">
              {gettext("New Feedback")} &check;
            </button>
          </:actions>
        </.editor>
      </div>

      <%!-- PHASE: Feedback --%>
      <div :if={@phase == :feedback}>
        <.loading
          :if={@feedback_loading}
          title={gettext("Feedback")}
          message={gettext("Your text is being reviewed")}
        />

        <.feedback_view
          :if={@feedback && !@feedback_loading}
          feedback={@feedback}
          error={@error}
        >
          <:actions>
            <.link
              navigate={~p"/entries/#{@entry.id}"}
              class="brutal-btn px-6 py-3 block-yellow no-underline text-lg"
            >
              {gettext("Back to entry")}
            </.link>
          </:actions>
        </.feedback_view>

        <div :if={@error && !@feedback_loading && !@feedback} class="space-y-6">
          <h1 class="text-4xl sm:text-5xl font-black tracking-tighter uppercase">
            {gettext("Feedback")}
          </h1>
          <hr class="brutal-hr" />
          <div class="border-4 border-ink p-5 block-red">
            <p class="font-mono text-sm">{@error}</p>
          </div>
          <.link
            navigate={~p"/entries/#{@entry.id}"}
            class="brutal-btn inline-block px-6 py-3 block-yellow no-underline text-lg"
          >
            {gettext("Back to entry")}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
