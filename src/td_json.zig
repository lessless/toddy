//! Minimal marshaling layer over libtdjson's td_json_client_* C ABI.
//! Per constitution Principle VI, this file MUST NOT contain TDLib request/response
//! parsing, business logic, or retry/orchestration — only string marshaling across
//! the FFI boundary and BEAM resource lifecycle management.

const std = @import("std");
const beam = @import("beam");
const root = @import("root");

const c = @cImport({
    @cInclude("td/telegram/td_json_client.h");
});

/// Wraps the opaque TDLib client pointer as a BEAM resource. The resource's
/// destructor calls td_json_client_destroy, so a client is cleaned up
/// automatically once its last Elixir reference is garbage collected.
pub const ClientHandle = beam.Resource(*anyopaque, root, .{ .Callbacks = ClientHandleCallbacks });

pub const ClientHandleCallbacks = struct {
    pub fn dtor(handle: **anyopaque) void {
        c.td_json_client_destroy(handle.*);
    }
};

pub fn create() !ClientHandle {
    const ptr = c.td_json_client_create() orelse return error.ClientCreateFailed;
    return ClientHandle.create(ptr, .{});
}

pub fn send(handle: ClientHandle, request: []const u8) !void {
    const request_z = try beam.allocator.dupeZ(u8, request);
    defer beam.allocator.free(request_z);

    c.td_json_client_send(handle.unpack(), request_z.ptr);
}

pub fn receive(handle: ClientHandle, timeout_seconds: f64) !?[]const u8 {
    const result = c.td_json_client_receive(handle.unpack(), timeout_seconds);
    const ptr = result orelse return null;

    const slice = std.mem.span(ptr);
    return try beam.allocator.dupe(u8, slice);
}

pub fn execute(request: []const u8) !?[]const u8 {
    const request_z = try beam.allocator.dupeZ(u8, request);
    defer beam.allocator.free(request_z);

    const result = c.td_json_client_execute(null, request_z.ptr);
    const ptr = result orelse return null;

    const slice = std.mem.span(ptr);
    return try beam.allocator.dupe(u8, slice);
}
