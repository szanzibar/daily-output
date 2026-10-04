defmodule DailyOutput.Planner do
  @moduledoc """
  Picks today's activity kind and creative angle. Pure: callers pass in the history, and the
  date seeds every pick, so a refresh never changes it.
  """

  # Days in which one is a journal, roughly.
  @journal_every 3
  @fresh_angles 3

  # {id, correction categories it draws out, instruction for the opener or prompt}.
  @angles [
    {"thread", ~w(verb vocabulary),
     "Pick up the thread of the last session and ask what happened since."},
    {"role-play", ~w(case preposition vocabulary),
     "Set up a short everyday role-play, like a shop, a doctor, or a hotel, and give the student their part."},
    {"what-if", ~w(verb word-order),
     "Pose a playful what-if: a hypothetical situation the student imagines their way through."},
    {"story", ~w(verb agreement), "Ask for a story from the student's own past."},
    {"debate", ~w(word-order vocabulary),
     "Take a light, friendly stance on a harmless topic and invite the student to argue the other side."},
    {"explain-how", ~w(word-order verb),
     "Ask the student to explain, step by step, how to do something they know well."},
    {"plan", ~w(preposition case verb),
     "Plan something together with the student: a trip, a dinner, or a weekend."},
    {"would-you-rather", ~w(gender case agreement),
     "Ask a would-you-rather question and have the student explain their choice."}
  ]

  @doc """
  `"conversation"` or `"journal"`. `recent_kinds` is the kind of each previous day's first
  activity, newest first. Never journals two days in a row.
  """
  def activity_kind(["journal" | _], _date), do: "conversation"

  def activity_kind(_recent_kinds, date) do
    if :erlang.phash2({:kind, date}, @journal_every) == 0, do: "journal", else: "conversation"
  end

  @doc """
  An angle id. Skips the last #{@fresh_angles} in `recent_angles` (newest first) and prefers
  angles that draw out `focus_category`.
  """
  def angle(recent_angles, focus_category, date) do
    used = Enum.take(recent_angles, @fresh_angles)
    fresh = Enum.reject(@angles, fn {id, _, _} -> id in used end)

    pool =
      case Enum.filter(fresh, fn {_, categories, _} -> focus_category in categories end) do
        [] -> fresh
        fitting -> fitting
      end

    {id, _, _} = Enum.at(pool, :erlang.phash2({:angle, date}, length(pool)))
    id
  end

  @doc "What the opener or prompt should do for angle `id`."
  def angle_instruction(id) do
    {_, _, instruction} = List.keyfind!(@angles, id, 0)
    instruction
  end
end
