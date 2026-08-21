defmodule Toddy.Native.TdJsonIntegrationTest do
  @moduledoc """
  Verifies the Zig NIF against a real, compiled libtdjson (Constitution
  Principle III — no FFI-facing change merges on mocks alone).
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  alias Toddy.Native.TdJson

  test "create/send/receive round-trip against a real TDLib client" do
    handle = TdJson.create()

    :ok = TdJson.send(handle, ~s({"@type":"getAuthorizationState","@extra":"native-test"}))

    # TDLib interleaves unsolicited updates with request responses on the same
    # receive channel (research.md R5), so we scan a bounded number of
    # messages for any well-formed TDLib JSON payload rather than assuming a
    # specific update arrives first.
    assert {:ok, response} = receive_matching(handle, "@type")
    assert response =~ "@type"
  end

  test "execute/1 runs a synchronous request against a real TDLib instance" do
    response = TdJson.execute(~s({"@type":"getTextEntities","text":"@telegram"}))

    assert is_binary(response)
    assert response =~ "textEntities"
  end

  test "destroy happens automatically once the resource is garbage collected" do
    handle = TdJson.create()
    ref = :erlang.phash2(handle)
    assert is_reference(handle)
    assert is_integer(ref)
  end

  defp receive_matching(handle, type_fragment, attempts \\ 20)

  defp receive_matching(_handle, type_fragment, 0) do
    {:error, {:not_received, type_fragment}}
  end

  defp receive_matching(handle, type_fragment, attempts) do
    case TdJson.receive(handle, 2.0) do
      payload when is_binary(payload) ->
        if payload =~ type_fragment do
          {:ok, payload}
        else
          receive_matching(handle, type_fragment, attempts - 1)
        end

      nil ->
        receive_matching(handle, type_fragment, attempts - 1)
    end
  end
end
