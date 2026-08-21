defmodule Toddy.MediaItem do
  @moduledoc """
  A media attachment on a message. `remote_file_id` (TDLib's content-based
  `remote.unique_id`) is the identity used for deduplication (FR-007) — two
  items with the same `remote_file_id` are the same download target
  regardless of filename or which message carried it. `file_id` is TDLib's
  session-scoped local file identifier, needed to actually trigger a
  download via `downloadFile` — a real TDLib API detail (a file has both a
  stable content identity and a separate local handle) not anticipated in
  the original data-model.md, added here once implementation needed it.
  """

  @enforce_keys [:remote_file_id, :file_id, :type, :size]
  defstruct [:remote_file_id, :file_id, :type, :size, :file_name]

  @type media_type :: :photo | :video | :document | :audio | :voice_note

  @type t :: %__MODULE__{
          remote_file_id: String.t(),
          file_id: integer(),
          type: media_type(),
          size: non_neg_integer(),
          file_name: String.t() | nil
        }
end

defmodule Toddy.Message do
  @moduledoc "A message in a group's history, with an optional media attachment."

  @enforce_keys [:id, :chat_id, :date]
  defstruct [:id, :chat_id, :date, :sender, media: nil]

  @type t :: %__MODULE__{
          id: integer(),
          chat_id: integer(),
          date: DateTime.t(),
          sender: String.t() | integer() | nil,
          media: Toddy.MediaItem.t() | nil
        }
end
