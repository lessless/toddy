defmodule Toddy.GroupTest do
  @moduledoc """
  User Story 2 (Find Media in a Group): group resolution, history pagination,
  and media-type filtering against a mocked native layer (FR-003, FR-004,
  FR-005; research.md R7).
  """
  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  alias Toddy.Group
  alias Toddy.Native.Mock
  alias Toddy.Session

  setup :set_mox_global
  setup :verify_on_exit!

  defp start_session(responder) do
    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)
    |> stub(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      response = responder.(decoded) |> Map.put("@extra", decoded["@extra"])
      send(self(), {:td_message, Jason.encode!(response)})
      :ok
    end)

    dir = Path.join(System.tmp_dir!(), "toddy_group_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    session
  end

  describe "find/2" do
    defp chat_list_responder(decoded) do
      case decoded["@type"] do
        "getChats" ->
          %{"@type" => "chats", "chat_ids" => [10, 20, 30]}

        "getChat" ->
          case decoded["chat_id"] do
            10 ->
              %{
                "@type" => "chat",
                "id" => 10,
                "title" => "Random DM",
                "type" => %{"@type" => "chatTypePrivate"}
              }

            20 ->
              %{
                "@type" => "chat",
                "id" => 20,
                "title" => "My Telegram Group",
                "type" => %{"@type" => "chatTypeSupergroup", "supergroup_id" => 999}
              }

            30 ->
              %{
                "@type" => "chat",
                "id" => 30,
                "title" => "Another Group",
                "type" => %{"@type" => "chatTypeBasicGroup", "basic_group_id" => 111}
              }
          end
      end
    end

    test "finds a group by exact title, scoped to the account's own chat list" do
      session = start_session(&chat_list_responder/1)

      assert {:ok, %Group{id: 20, title: "My Telegram Group"}} =
               Group.find(session, "My Telegram Group")
    end

    test "finds a group by id" do
      session = start_session(&chat_list_responder/1)
      assert {:ok, %Group{id: 30, title: "Another Group"}} = Group.find(session, 30)
    end

    test "returns :group_not_found for a chat that isn't a group (e.g. a private DM)" do
      session = start_session(&chat_list_responder/1)
      assert Group.find(session, "Random DM") == {:error, :group_not_found}
    end

    test "returns :group_not_found and logs, rather than an empty result, for an unknown identifier" do
      session = start_session(&chat_list_responder/1)

      log =
        capture_log(fn ->
          assert Group.find(session, "Does Not Exist") == {:error, :group_not_found}
        end)

      assert log =~ "toddy.wide_event event=group_find"
      assert log =~ "outcome=not_found"
    end
  end

  describe "list_media/2" do
    defp message(id, content) do
      %{
        "@type" => "message",
        "id" => id,
        "chat_id" => 20,
        "date" => 1_700_000_000,
        "sender_id" => %{"@type" => "messageSenderUser", "user_id" => 555},
        "content" => content
      }
    end

    defp file(id, size, unique_id),
      do: %{"id" => id, "size" => size, "remote" => %{"unique_id" => unique_id}}

    defp text_content,
      do: %{"@type" => "messageText", "text" => %{"@type" => "formattedText", "text" => "hi"}}

    defp photo_content(unique_id),
      do: %{
        "@type" => "messagePhoto",
        "photo" => %{"sizes" => [%{"photo" => file(1, 111, unique_id)}]}
      }

    defp document_content(unique_id),
      do: %{
        "@type" => "messageDocument",
        "document" => %{"document" => file(2, 222, unique_id), "file_name" => "report.pdf"}
      }

    defp video_content(unique_id),
      do: %{
        "@type" => "messageVideo",
        "video" => %{"video" => file(3, 333, unique_id), "file_name" => "clip.mp4"}
      }

    test "returns only messages with media, across paginated history, in TDLib content-type order" do
      session =
        start_session(fn decoded ->
          case decoded["from_message_id"] do
            0 ->
              %{
                "@type" => "messages",
                "messages" => [
                  message(100, text_content()),
                  message(99, photo_content("photo-1")),
                  message(98, document_content("doc-1"))
                ]
              }

            98 ->
              %{"@type" => "messages", "messages" => [message(97, video_content("vid-1"))]}

            97 ->
              %{"@type" => "messages", "messages" => []}
          end
        end)

      group = %Group{id: 20, title: "My Telegram Group"}

      log =
        capture_log(fn ->
          assert {:ok, messages} = Group.list_media(session, group)
          send(self(), {:messages, messages})
        end)

      assert_received {:messages, messages}

      assert Enum.map(messages, & &1.id) == [99, 98, 97]
      assert Enum.map(messages, & &1.media.type) == [:photo, :document, :video]
      assert Enum.map(messages, & &1.media.remote_file_id) == ["photo-1", "doc-1", "vid-1"]

      assert log =~ "toddy.wide_event event=group_list_media"
      assert log =~ "media_count=3"
      assert log =~ "pages_fetched=3"
      assert Enum.find(messages, &(&1.id == 98)).media.file_name == "report.pdf"
    end

    test "returns an empty list for a group with no media" do
      session = start_session(fn _decoded -> %{"@type" => "messages", "messages" => []} end)
      group = %Group{id: 20, title: "My Telegram Group"}
      assert Group.list_media(session, group) == {:ok, []}
    end
  end
end
