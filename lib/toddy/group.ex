defmodule Toddy.Group do
  @moduledoc """
  Locating a group the authenticated account belongs to, and listing its
  media-bearing messages (User Story 2 — FR-003, FR-004, FR-005).
  """

  alias Toddy.MediaItem
  alias Toddy.Message
  alias Toddy.Probes
  alias Toddy.Session

  @enforce_keys [:id, :title]
  defstruct [:id, :title]

  @type t :: %__MODULE__{id: integer(), title: String.t()}

  @group_types ~w[chatTypeBasicGroup chatTypeSupergroup]
  @max_history_pages 200
  @history_page_size 100

  @doc """
  Resolves a group the authenticated account belongs to, by TDLib chat id or
  exact title. Scoped to the account's own chat list, so membership (FR-004)
  is implicit — a chat that isn't a basic group or supergroup the account
  belongs to returns `{:error, :group_not_found}`, never an empty result.
  """
  @spec find(GenServer.server(), integer() | String.t()) ::
          {:ok, Toddy.Group.t()} | {:error, :group_not_found}
  def find(session, identifier) do
    case find_in_chat_list(session, identifier) do
      {:ok, group} ->
        {:ok, group}

      :error ->
        Probes.group_not_found(identifier)
        {:error, :group_not_found}
    end
  end

  @doc """
  Returns every message in the group's existing history (as of now — FR-012,
  no live/streaming mode) that carries a photo, video, document, or
  audio/voice attachment.
  """
  @spec list_media(GenServer.server(), Toddy.Group.t()) :: {:ok, [Message.t()]}
  def list_media(session, %__MODULE__{id: chat_id}) do
    {:ok, paginate_history(session, chat_id, 0, [], @max_history_pages)}
  end

  # Internal: group resolution, scoped to the account's own chat list so
  # membership (FR-004) is implicit rather than separately checked.

  defp find_in_chat_list(session, identifier) do
    request = %{
      "@type" => "getChats",
      "chat_list" => %{"@type" => "chatListMain"},
      "limit" => 200
    }

    case Session.request(session, request) do
      %{"@type" => "chats", "chat_ids" => chat_ids} ->
        Enum.reduce_while(chat_ids, :error, fn chat_id, acc ->
          case fetch_chat(session, chat_id) do
            {:ok, chat} ->
              if group_match?(chat, identifier),
                do: {:halt, {:ok, to_group(chat)}},
                else: {:cont, acc}

            :error ->
              {:cont, acc}
          end
        end)

      _other ->
        :error
    end
  end

  defp fetch_chat(session, chat_id) do
    case Session.request(session, %{"@type" => "getChat", "chat_id" => chat_id}) do
      %{"@type" => "chat"} = chat -> {:ok, chat}
      _other -> :error
    end
  end

  defp group_match?(%{"id" => id, "title" => title, "type" => %{"@type" => type}}, identifier) do
    type in @group_types and (id == identifier or title == identifier)
  end

  defp group_match?(_chat, _identifier), do: false

  defp to_group(%{"id" => id, "title" => title}), do: %__MODULE__{id: id, title: title}

  # Internal: media discovery via getChatHistory pagination (research.md R7)

  defp paginate_history(_session, _chat_id, _from_id, acc, 0), do: acc

  defp paginate_history(session, chat_id, from_message_id, acc, pages_left) do
    request = %{
      "@type" => "getChatHistory",
      "chat_id" => chat_id,
      "from_message_id" => from_message_id,
      "offset" => 0,
      "limit" => @history_page_size,
      "only_local" => false
    }

    case Session.request(session, request) do
      %{"@type" => "messages", "messages" => []} ->
        acc

      %{"@type" => "messages", "messages" => raw_messages} ->
        media_messages =
          raw_messages
          |> Enum.map(&to_message/1)
          |> Enum.filter(& &1.media)

        last_id = raw_messages |> List.last() |> Map.fetch!("id")
        paginate_history(session, chat_id, last_id, acc ++ media_messages, pages_left - 1)

      _other ->
        acc
    end
  end

  defp to_message(raw) do
    %Message{
      id: raw["id"],
      chat_id: raw["chat_id"],
      date: DateTime.from_unix!(raw["date"]),
      sender: sender_of(raw["sender_id"]),
      media: media_of(raw["content"])
    }
  end

  defp sender_of(%{"@type" => "messageSenderUser", "user_id" => id}), do: id
  defp sender_of(%{"@type" => "messageSenderChat", "chat_id" => id}), do: id
  defp sender_of(_other), do: nil

  defp media_of(%{"@type" => "messagePhoto", "photo" => %{"sizes" => sizes}}) do
    case List.last(sizes) do
      %{"photo" => file} -> media_item(file, :photo, nil)
      _other -> nil
    end
  end

  defp media_of(%{"@type" => "messageVideo", "video" => %{"video" => file, "file_name" => name}}) do
    media_item(file, :video, name)
  end

  defp media_of(%{
         "@type" => "messageDocument",
         "document" => %{"document" => file, "file_name" => name}
       }) do
    media_item(file, :document, name)
  end

  defp media_of(%{"@type" => "messageAudio", "audio" => %{"audio" => file, "file_name" => name}}) do
    media_item(file, :audio, name)
  end

  defp media_of(%{"@type" => "messageVoiceNote", "voice_note" => %{"voice" => file}}) do
    media_item(file, :voice_note, nil)
  end

  defp media_of(_other), do: nil

  defp media_item(
         %{"id" => file_id, "size" => size, "remote" => %{"unique_id" => remote_id}},
         type,
         name
       )
       when is_binary(remote_id) and remote_id != "" do
    %MediaItem{
      remote_file_id: remote_id,
      file_id: file_id,
      type: type,
      size: size,
      file_name: name
    }
  end

  defp media_item(_file, _type, _name), do: nil
end
