defmodule DailyOutput.Repo.Migrations.AddFlashcardsAtToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # When set, this user message's corrections have already been turned into flashcards.
      # Lets a continued+recompleted conversation card only the NEW turns and never re-card
      # the ones an earlier completion already handled (the watermark is copied forward when
      # a conversation is branched — see `Conversations.copy_message/2`).
      add :flashcards_at, :utc_datetime
    end
  end
end
