# Ensure default settings exist
alias DailyOutput.Settings

case Settings.ensure_config() do
  {:ok, _config} -> IO.puts("Settings: OK")
  {:error, changeset} -> IO.inspect(changeset.errors, label: "Settings error")
end
