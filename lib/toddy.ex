defmodule Toddy do
  @moduledoc """
  A minimal Elixir wrapper over TDLib: authenticate a personal Telegram
  account, locate a group you belong to, and download that group's existing
  media to local storage.

  This module is a thin, optional convenience facade — `Toddy.Session`,
  `Toddy.Group`, and `Toddy.Download` (see `contracts/toddy_api.md` in the
  repo) are the modules that actually implement each capability and can be
  called directly.

  ## Example

      {:ok, session} =
        Toddy.Session.start_link(
          phone_number: "+15551234567",
          session_dir: "./tmp/session",
          api_id: System.fetch_env!("TG_API_ID") |> String.to_integer(),
          api_hash: System.fetch_env!("TG_API_HASH")
        )

      Toddy.Session.submit_code(session, "12345")

      {:ok, group} = Toddy.Group.find(session, "My Telegram Group")
      {:ok, media_messages} = Toddy.Group.list_media(session, group)
      Toddy.Download.fetch_all(session, media_messages, "./tmp/downloads")

  See the [README](readme.html) for full setup instructions.
  """

  defdelegate start_session(opts), to: Toddy.Session, as: :start_link
  defdelegate status(session), to: Toddy.Session
  defdelegate submit_code(session, code), to: Toddy.Session
  defdelegate submit_password(session, password), to: Toddy.Session

  defdelegate find_group(session, identifier), to: Toddy.Group, as: :find
  defdelegate list_media(session, group), to: Toddy.Group

  defdelegate download(session, message, destination_path), to: Toddy.Download, as: :fetch
  defdelegate download_all(session, messages, destination_dir), to: Toddy.Download, as: :fetch_all
end
