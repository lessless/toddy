defmodule Toddy.Native.TdJson do
  @moduledoc """
  Thin Zigler NIF wrapper over libtdjson's td_json_client_* C ABI.

  Per constitution Principle VI, this module is limited to marshaling and
  dirty-scheduler wiring; all TDLib request/response knowledge lives in
  `Toddy.Session` and friends, not here.

  Requires `libtdjson` (TDLib's JSON-interface shared library) to be
  discoverable via `pkg-config tdjson` at compile time — see README.md for
  installation instructions.
  """

  @behaviour Toddy.Native.Behaviour

  {pkg_cflags, 0} = System.cmd("pkg-config", ["--cflags-only-I", "tdjson"])
  {pkg_libs, 0} = System.cmd("pkg-config", ["--libs-only-L", "tdjson"])

  @tdjson_include_dirs pkg_cflags
                       |> String.split()
                       |> Enum.map(&String.trim_leading(&1, "-I"))

  @tdjson_library_dirs pkg_libs
                       |> String.split()
                       |> Enum.map(&String.trim_leading(&1, "-L"))

  use Zig,
    otp_app: :toddy,
    zig_code_path: "../../../src/td_json.zig",
    resources: [:ClientHandle],
    c: [
      include_dirs: @tdjson_include_dirs,
      library_dirs: @tdjson_library_dirs,
      link_lib: [{:system, "tdjson"}]
    ],
    nifs: [
      create: [],
      send: [:dirty_io],
      receive: [:dirty_io],
      execute: [:dirty_io]
    ]
end
