defmodule DailyOutputWeb.EntryLive.NewTest do
  use DailyOutputWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DailyOutput.{FocusTopics, Journal}

  test "creates a persisted draft with focus and navigates to edit", %{conn: conn} do
    focus_topic =
      create_focus_topic!(%{
        text: "Use dative case",
        source_type: "entry"
      })

    prompt = "Erzaehl von deinem Tag in Zuerich"

    {:ok, view, _html} = live(conn, ~p"/entries/new")

    render_click(view, "select_prompt", %{"prompt" => prompt})

    assert has_element?(
             view,
             ~s(button[phx-click="select_focus_topic"][phx-value-id="#{focus_topic.id}"])
           )

    render_click(view, "select_focus_topic", %{"id" => Integer.to_string(focus_topic.id)})

    {path, _flash} = assert_redirect(view)
    [_, id] = Regex.run(~r|^/entries/(\d+)/edit$|, path)

    entry = Journal.get_entry!(String.to_integer(id))
    entry_id = entry.id

    assert entry.prompt == prompt
    assert entry.focus_topic_id == focus_topic.id
    assert is_nil(entry.feedback)

    {:ok, edit_view, _html} = live(conn, path)
    assert has_element?(edit_view, "div.block-blue span", focus_topic.text)

    draft_body = "Heute habe ich mit viel Fokus geschrieben."
    render_hook(edit_view, "update_body", %{"body" => draft_body})

    assert Journal.get_entry!(entry_id).body == draft_body

    {:ok, resumed_edit_view, _html} = live(conn, path)
    assert has_element?(resumed_edit_view, "textarea#editor-#{entry_id}", draft_body)
  end

  defp create_focus_topic!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      text: "Focus #{unique}",
      source_text: "source-#{unique}",
      source_type: "entry",
      source_id: unique
    }

    {:ok, topic} = FocusTopics.create_topic(Map.merge(defaults, attrs))
    topic
  end
end
