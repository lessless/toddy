defmodule Toddy.Native.Behaviour do
  @moduledoc """
  Contract implemented by `Toddy.Native.TdJson` (the real NIF) and mocked in
  unit tests, so `Toddy.Session` never depends on the native module directly.
  """

  @callback create() :: reference()
  @callback send(reference(), binary()) :: :ok
  @callback receive(reference(), float()) :: binary() | nil
  @callback execute(binary()) :: binary() | nil
end
