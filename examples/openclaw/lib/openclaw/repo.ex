defmodule Openclaw.Repo do
  use Ecto.Repo,
    otp_app: :openclaw,
    adapter: Ecto.Adapters.SQLite3
end
