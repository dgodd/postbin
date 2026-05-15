# postbin — codebase notes

## Build & run

```sh
zig build          # compile
zig build run      # compile and run
./zig-out/bin/postbin
```

## Structure

```
src/main.zig   — entire implementation (~270 lines, no external deps)
src/root.zig   — generated stub from zig init, unused
build.zig      — minimal build script, single executable target
```

## Architecture

Single-threaded HTTP server. Connections are accepted in a loop and handled one at a time (sequential, no threads). State lives in a global `State` struct backed by the process-lifetime arena allocator (`std.process.Init.arena`).

**Request flow:**

1. `main` — listens, accepts TCP connections, calls `handleConn`
2. `handleConn` — wraps the TCP stream in `std.http.Server`, loops calling `receiveHead` for keep-alive
3. `handleRequest` — routes: `GET /` → `serveUI`, everything else → capture + respond 200
4. `serveUI` — generates HTML into a `Writer.Allocating`, passes the buffer to `respond`

## Zig 0.16 API notes

This codebase uses APIs that changed substantially in 0.16:

**`std.Io` / networking**
- `std.Io` is the new abstraction over all I/O. Get an instance from `std.process.Init.io`.
- TCP server: `std.Io.net.IpAddress{ .ip4 = .unspecified(port) }.listen(io, .{ .reuse_address = true })` → `net.Server`
- Accept: `server.accept(io)` → `net.Stream`
- Reader/writer: `stream.reader(io, &buf)` / `stream.writer(io, &buf)` → typed structs with `.interface: std.Io.Reader/Writer`

**`std.http.Server`**
- `http.Server.init(&reader.interface, &writer.interface)` — takes `*std.Io.Reader` and `*std.Io.Writer`
- `server.receiveHead()` → `Request`; returns `error.HttpConnectionClosing` when the client closes
- **Head pointer invalidation**: `request.head.target`, `request.head.content_type`, and all header values returned by `iterateHeaders()` point into the receive buffer. They are invalidated when the body reader is initialised. Copy them with `arena.dupe` before calling `readerExpectContinue`.
- `request.iterateHeaders()` — skips the request line, returns only headers
- `request.readerExpectContinue(&transfer_buf)` — handles `Expect: 100-continue`, returns `*std.Io.Reader`; for methods without a body (GET, DELETE…) returns `.ending`, and `allocRemaining` on it yields `""`
- `body_reader.allocRemaining(arena, .limited(max_body_size))` — reads entire body into arena-owned slice

**`std.ArrayList` (now unmanaged)**
- `std.ArrayList(T)` = `array_list.Aligned(T, null)` — the allocator is **not** stored; pass it to every call
- Init: `var list: std.ArrayList(T) = .empty;`
- Append: `list.append(allocator, item)`
- Consume: `list.toOwnedSlice(allocator)`

**`std.Io.Writer.Allocating`**
- Growable writer backed by an allocator: `var out: std.Io.Writer.Allocating = .init(allocator);`
- Access written bytes (without consuming): `out.written()` → `[]u8`
- Take ownership: `out.toOwnedSlice()` → `Allocator.Error![]u8`
- `out.deinit()` frees the buffer if not already consumed

**JSON**
- Parse: `std.json.parseFromSlice(std.json.Value, allocator, input, .{})`
- Pretty-print: `std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 })`

**`main` signature**
```zig
pub fn main(init: std.process.Init) !void
```
- `init.io` — the `std.Io` instance
- `init.arena` — `*std.heap.ArenaAllocator` for process-lifetime storage
- `init.gpa` — general-purpose allocator for temporary allocations
