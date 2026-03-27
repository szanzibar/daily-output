# Ensure default settings exist
alias Sprachjournal.Settings

case Settings.ensure_config() do
  {:ok, _config} -> IO.puts("Settings: OK")
  {:error, changeset} -> IO.inspect(changeset.errors, label: "Settings error")
end
