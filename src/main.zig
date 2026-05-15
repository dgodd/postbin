const std = @import("std");
const net = std.Io.net;
const http = std.http;

const max_body_size = 4 * 1024 * 1024; // 4MB cap on captured bodies

const favicon = @embedFile("favicon.ico");

const StoredHeader = struct {
    name: []const u8,
    value: []const u8,
};

const CapturedRequest = struct {
    id: u32,
    method: []const u8,
    path: []const u8,
    headers: []const StoredHeader,
    body: []const u8,
    pretty_body: []const u8,
    is_json: bool,
};

const State = struct {
    arena: std.mem.Allocator,
    requests: std.ArrayList(CapturedRequest) = .empty,
    next_id: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var state = State{
        .arena = arena,
    };

    const port: u16 = if (init.environ_map.get("PORT")) |s|
        std.fmt.parseInt(u16, s, 10) catch 8080
    else
        8080;
    const address = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.log.info("PostBin listening on http://localhost:{d}/", .{port});
    std.log.info("Send requests to any path except GET / to capture them.", .{});

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handleConn(io, &state, stream) catch |err| {
            std.log.err("connection error: {s}", .{@errorName(err)});
        };
    }
}

fn handleConn(io: std.Io, state: *State, stream: net.Stream) !void {
    defer {
        var s = stream;
        s.close(io);
    }

    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);
    var server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => |e| return e,
        };
        handleRequest(state, &req) catch |err| {
            std.log.err("request handling error: {s}", .{@errorName(err)});
            return;
        };
    }
}

fn handleRequest(state: *State, req: *http.Server.Request) !void {
    const arena = state.arena;

    // Determine if this is a UI viewer request before copying
    const is_ui = req.head.method == .GET and
        (std.mem.eql(u8, req.head.target, "/") or
        std.mem.startsWith(u8, req.head.target, "/?"));
    const is_favicon = req.head.method == .GET and
        std.mem.eql(u8, req.head.target, "/favicon.ico");

    if (is_ui) {
        return serveUI(arena, state, req);
    }
    if (is_favicon) {
        return req.respond(favicon, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/x-icon" },
                .{ .name = "cache-control", .value = "public, max-age=86400" },
            },
        });
    }

    // Copy head data now — body reading will invalidate head string pointers
    const method = @tagName(req.head.method);
    const path = try arena.dupe(u8, req.head.target);
    const content_type_raw = req.head.content_type;
    const content_type = if (content_type_raw) |ct| try arena.dupe(u8, ct) else null;

    // Collect headers
    var header_list: std.ArrayList(StoredHeader) = .empty;
    var hit = req.iterateHeaders();
    while (hit.next()) |h| {
        try header_list.append(arena, .{
            .name = try arena.dupe(u8, h.name),
            .value = try arena.dupe(u8, h.value),
        });
    }

    // Read body — this invalidates head string pointers
    var transfer_buf: [4096]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&transfer_buf);
    const body = try body_reader.allocRemaining(arena, .limited(max_body_size));

    // Detect JSON and pretty-print
    const is_json = looksLikeJson(content_type, body);
    const pretty_body = if (is_json) prettyJson(arena, body) catch body else body;

    const id = state.next_id;
    state.next_id += 1;

    try state.requests.append(arena, .{
        .id = id,
        .method = method,
        .path = path,
        .headers = try header_list.toOwnedSlice(arena),
        .body = body,
        .pretty_body = pretty_body,
        .is_json = is_json,
    });

    // Terminal log
    std.log.info("[#{d}] {s} {s}  ({d} bytes)", .{ id, method, path, body.len });
    for (state.requests.items[state.requests.items.len - 1].headers) |h| {
        std.log.info("  {s}: {s}", .{ h.name, h.value });
    }
    if (body.len > 0) {
        const preview_len = @min(pretty_body.len, 300);
        std.log.info("  Body: {s}{s}", .{
            pretty_body[0..preview_len],
            if (pretty_body.len > 300) " ..." else "",
        });
    }

    try req.respond("Captured!\n", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });
}

fn serveUI(arena: std.mem.Allocator, state: *const State, req: *http.Server.Request) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<meta http-equiv="refresh" content="5">
        \\<title>PostBin</title>
        \\<style>
        \\*{box-sizing:border-box;margin:0;padding:0}
        \\body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f0f2f5;color:#333}
        \\.topbar{background:#1a1a2e;color:#fff;padding:14px 24px;display:flex;align-items:center;gap:12px}
        \\.topbar h1{font-size:1.3em;font-weight:700;letter-spacing:.5px}
        \\.badge{background:#e94560;padding:3px 10px;border-radius:12px;font-size:.8em;font-weight:600}
        \\.hint{margin-left:auto;color:#aaa;font-size:.8em}
        \\.container{max-width:1000px;margin:0 auto;padding:20px 16px}
        \\.empty{text-align:center;padding:80px 20px;color:#888}
        \\.empty h2{font-size:1.3em;margin-bottom:8px;font-weight:500}
        \\.empty code{background:#e8e8e8;padding:2px 8px;border-radius:4px;font-size:.9em}
        \\.card{background:#fff;border-radius:8px;margin-bottom:16px;box-shadow:0 1px 3px rgba(0,0,0,.08);overflow:hidden}
        \\.card-head{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #f0f0f0}
        \\.req-id{color:#bbb;font-size:.75em;font-weight:600;min-width:28px}
        \\.method{padding:3px 9px;border-radius:4px;font-weight:700;font-size:.78em;color:#fff;text-transform:uppercase}
        \\.m-GET{background:#61affe}.m-POST{background:#49cc90}.m-PUT{background:#fca130}
        \\.m-DELETE{background:#f93e3e}.m-PATCH{background:#50e3c2;color:#333}.m-other{background:#9012fe}
        \\.path{font-family:monospace;font-size:.9em;flex:1;word-break:break-all}
        \\.size{color:#bbb;font-size:.75em;white-space:nowrap}
        \\.section{padding:10px 16px}
        \\.sec-title{font-size:.7em;font-weight:700;text-transform:uppercase;color:#aaa;letter-spacing:.06em;margin-bottom:6px}
        \\.hgrid{display:grid;grid-template-columns:auto 1fr;gap:2px 12px;font-size:.82em}
        \\.hn{color:#999;font-family:monospace;white-space:nowrap}
        \\.hv{font-family:monospace;word-break:break-all}
        \\hr.div{border:none;border-top:1px solid #f0f0f0}
        \\pre{background:#f7f7f7;padding:12px;font-size:.82em;overflow-x:auto;white-space:pre-wrap;word-break:break-all;line-height:1.5}
        \\pre.json{background:#1e1e2e;color:#cdd6f4}
        \\</style>
        \\</head><body>
    );

    try w.print(
        \\<div class="topbar">
        \\<h1>PostBin</h1>
        \\<span class="badge">{d} request{s}</span>
        \\<span class="hint">auto-refresh every 5 s</span>
        \\</div>
        \\<div class="container">
    , .{ state.requests.items.len, if (state.requests.items.len == 1) "" else "s" });

    if (state.requests.items.len == 0) {
        try w.writeAll(
            \\<div class="empty">
            \\<h2>No requests captured yet</h2>
            \\<p>Send any HTTP request to this server — for example:</p>
            \\<br>
            \\<code>curl -X POST http://localhost:8080/test -d '{"hello":"world"}' -H 'Content-Type: application/json'</code>
            \\</div>
        );
    } else {
        var i: usize = state.requests.items.len;
        while (i > 0) {
            i -= 1;
            try renderCard(w, &state.requests.items[i]);
        }
    }

    try w.writeAll("</div></body></html>");
    try w.flush();

    try req.respond(out.written(), .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}

fn renderCard(w: *std.Io.Writer, r: *const CapturedRequest) !void {
    const method_class = for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH" }) |m| {
        if (std.mem.eql(u8, r.method, m)) break m;
    } else "other";

    try w.writeAll("<div class=\"card\">");
    try w.print(
        \\<div class="card-head">
        \\<span class="req-id">#{d}</span>
        \\<span class="method m-{s}">{s}</span>
        \\<span class="path">
    , .{ r.id, method_class, r.method });
    try writeHtmlEscaped(w, r.path);
    try w.print("</span><span class=\"size\">{d} B</span></div>", .{r.body.len});

    if (r.headers.len > 0) {
        try w.writeAll("<div class=\"section\"><div class=\"sec-title\">Headers</div><div class=\"hgrid\">");
        for (r.headers) |h| {
            try w.writeAll("<span class=\"hn\">");
            try writeHtmlEscaped(w, h.name);
            try w.writeAll("</span><span class=\"hv\">");
            try writeHtmlEscaped(w, h.value);
            try w.writeAll("</span>");
        }
        try w.writeAll("</div></div>");
    }

    if (r.body.len > 0) {
        try w.writeAll("<hr class=\"div\">");
        try w.writeAll("<div class=\"section\"><div class=\"sec-title\">");
        if (r.is_json) {
            try w.writeAll("Body &mdash; JSON");
        } else {
            try w.writeAll("Body");
        }
        try w.writeAll("</div>");
        if (r.is_json) {
            try w.writeAll("<pre class=\"json\">");
        } else {
            try w.writeAll("<pre>");
        }
        try writeHtmlEscaped(w, r.pretty_body);
        try w.writeAll("</pre></div>");
    }

    try w.writeAll("</div>");
}

fn writeHtmlEscaped(w: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const entity: []const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            else => continue,
        };
        try w.writeAll(text[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    try w.writeAll(text[start..]);
}

fn looksLikeJson(content_type: ?[]const u8, body: []const u8) bool {
    if (content_type) |ct| {
        if (std.mem.indexOf(u8, ct, "json") != null) return true;
    }
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return false;
    return trimmed[0] == '{' or trimmed[0] == '[';
}

fn prettyJson(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, input, .{});
    defer parsed.deinit();
    return try std.json.Stringify.valueAlloc(arena, parsed.value, .{ .whitespace = .indent_2 });
}

// ---- Tests ---------------------------------------------------------------

const testing = std.testing;

fn testRequest(state: *State, raw: []const u8) !std.Io.Writer.Allocating {
    var reader = std.Io.Reader.fixed(raw);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var srv = http.Server.init(&reader, &out.writer);
    var req = try srv.receiveHead();
    try handleRequest(state, &req);
    return out;
}

test "looksLikeJson: content-type detection" {
    try testing.expect(looksLikeJson("application/json", ""));
    try testing.expect(looksLikeJson("application/vnd.api+json", ""));
    // non-json content-type falls through to body heuristic
    try testing.expect(!looksLikeJson("text/plain", "hello"));
    try testing.expect(!looksLikeJson("text/html", "not json"));
}

test "looksLikeJson: body heuristic" {
    try testing.expect(looksLikeJson(null, "{}"));
    try testing.expect(looksLikeJson(null, "[]"));
    try testing.expect(looksLikeJson(null, "  { }  "));
    try testing.expect(!looksLikeJson(null, "hello world"));
    try testing.expect(!looksLikeJson(null, ""));
}

test "prettyJson: formats valid JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try prettyJson(arena.allocator(), "{\"a\":1}");
    try testing.expect(std.mem.indexOfScalar(u8, result, '\n') != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"a\"") != null);
}

test "prettyJson: error on invalid input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, prettyJson(arena.allocator(), "not json"));
}

test "writeHtmlEscaped: plain text passthrough" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHtmlEscaped(&out.writer, "hello world");
    try testing.expectEqualStrings("hello world", out.written());
}

test "writeHtmlEscaped: special characters" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHtmlEscaped(&out.writer, "<b>&\"x\"</b>");
    try testing.expectEqualStrings("&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;", out.written());
}

test "GET / returns 200 with HTML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State{ .arena = arena.allocator() };
    var out = try testRequest(&state, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const resp = out.written();
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "PostBin") != null);
}

test "GET /favicon.ico returns image/x-icon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State{ .arena = arena.allocator() };
    var out = try testRequest(&state, "GET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const resp = out.written();
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "image/x-icon") != null);
}

test "POST captures method, path, and body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State{ .arena = arena.allocator() };
    const raw =
        "POST /webhook HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";
    var out = try testRequest(&state, raw);
    defer out.deinit();
    try testing.expect(std.mem.indexOf(u8, out.written(), "Captured!") != null);
    try testing.expectEqual(@as(usize, 1), state.requests.items.len);
    const captured = state.requests.items[0];
    try testing.expectEqualStrings("POST", captured.method);
    try testing.expectEqualStrings("/webhook", captured.path);
    try testing.expectEqualStrings("hello", captured.body);
}

test "POST with JSON content-type is detected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = State{ .arena = arena.allocator() };
    const raw =
        "POST /api HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 7\r\n" ++
        "\r\n" ++
        "{\"x\":1}";
    var out = try testRequest(&state, raw);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), state.requests.items.len);
    const captured = state.requests.items[0];
    try testing.expect(captured.is_json);
    try testing.expect(std.mem.indexOfScalar(u8, captured.pretty_body, '\n') != null);
}
