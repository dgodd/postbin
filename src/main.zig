const std = @import("std");
const net = std.Io.net;
const http = std.http;

const max_body_size = 4 * 1024 * 1024;
const max_requests = 100;

const favicon = @embedFile("favicon.ico");

const StoredHeader = struct {
    name: []const u8,
    value: []const u8,
};

const SerHeader = struct {
    name: []const u8,
    value: []const u8,
};
const SerializedRequest = struct {
    id: u32,
    bin_id: []const u8,
    method: []const u8,
    path: []const u8,
    headers: []SerHeader,
    body: []const u8, // base64-encoded
    is_json: bool,
};

const CapturedRequest = struct {
    id: u32,
    bin_id: []const u8,
    method: []const u8,
    path: []const u8,
    headers: []const StoredHeader,
    body: []const u8,
    pretty_body: []const u8,
    is_json: bool,
};

const State = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    data_path: []const u8,
    requests: std.ArrayList(CapturedRequest) = .empty,
    next_id: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const data_path: []const u8 = if (init.environ_map.get("POSTBIN_DATA")) |p|
        try arena.dupe(u8, p)
    else
        "postbin.ndjson";

    var state = State{
        .io = io,
        .arena = arena,
        .gpa = gpa,
        .data_path = data_path,
    };

    loadRequests(&state) catch |err| {
        std.log.warn("could not load existing requests from '{s}': {s}", .{ data_path, @errorName(err) });
    };

    const port: u16 = if (init.environ_map.get("PORT")) |s|
        std.fmt.parseInt(u16, s, 10) catch 8080
    else
        8080;
    const address = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.log.info("PostBin listening on http://localhost:{d}/", .{port});

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

fn isValidBinId(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
}

// Returns a slice of target[1..37] when target starts with /<uuid> (followed by nothing, /, or ?).
fn extractBinId(target: []const u8) ?[]const u8 {
    if (target.len < 37) return null;
    if (target[0] != '/') return null;
    const candidate = target[1..37];
    if (!isValidBinId(candidate)) return null;
    if (target.len > 37 and target[37] != '/' and target[37] != '?') return null;
    return candidate;
}

fn handleRequest(state: *State, req: *http.Server.Request) !void {
    const target = req.head.target;
    const method = req.head.method;

    if (method == .GET and (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?"))) {
        return serveLanding(state.arena, state, req);
    }
    if (method == .GET and std.mem.eql(u8, target, "/favicon.ico")) {
        return req.respond(favicon, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/x-icon" },
                .{ .name = "cache-control", .value = "public, max-age=86400" },
            },
        });
    }

    if (extractBinId(target)) |bin_id| {
        const after_uuid = target[37..];
        const is_bin_view = method == .GET and
            (after_uuid.len == 0 or
            after_uuid[0] == '?' or
            std.mem.eql(u8, after_uuid, "/") or
            std.mem.startsWith(u8, after_uuid, "/?"));
        if (is_bin_view) {
            return serveBinUI(state.arena, state, bin_id, req);
        }
        return captureRequest(state, bin_id, req);
    }

    try req.respond("Not Found\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

fn captureRequest(state: *State, bin_id: []const u8, req: *http.Server.Request) !void {
    const arena = state.arena;

    const method = @tagName(req.head.method);
    const path = try arena.dupe(u8, req.head.target);
    const content_type_raw = req.head.content_type;
    const content_type = if (content_type_raw) |ct| try arena.dupe(u8, ct) else null;
    const bin_id_owned = try arena.dupe(u8, bin_id);

    var header_list: std.ArrayList(StoredHeader) = .empty;
    var hit = req.iterateHeaders();
    while (hit.next()) |h| {
        try header_list.append(arena, .{
            .name = try arena.dupe(u8, h.name),
            .value = try arena.dupe(u8, h.value),
        });
    }

    var transfer_buf: [4096]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&transfer_buf);
    const body = try body_reader.allocRemaining(arena, .limited(max_body_size));

    const is_json = looksLikeJson(content_type, body);
    const pretty_body = if (is_json) prettyJson(arena, body) catch body else body;

    const id = state.next_id;
    state.next_id += 1;

    const new_req = CapturedRequest{
        .id = id,
        .bin_id = bin_id_owned,
        .method = method,
        .path = path,
        .headers = try header_list.toOwnedSlice(arena),
        .body = body,
        .pretty_body = pretty_body,
        .is_json = is_json,
    };

    appendRequestToLog(state, &new_req) catch |err| {
        std.log.warn("could not write request to log: {s}", .{@errorName(err)});
    };

    try state.requests.append(arena, new_req);
    capBin(state, bin_id_owned);

    std.log.info("[#{d}] [{s}] {s} {s}  ({d} bytes)", .{ id, bin_id_owned[0..8], method, path, body.len });
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

fn capBin(state: *State, bin_id: []const u8) void {
    var count: usize = 0;
    for (state.requests.items) |r| {
        if (std.mem.eql(u8, r.bin_id, bin_id)) count += 1;
    }
    var i: usize = 0;
    while (count > max_requests) {
        if (i >= state.requests.items.len) break;
        if (std.mem.eql(u8, state.requests.items[i].bin_id, bin_id)) {
            _ = state.requests.orderedRemove(i);
            count -= 1;
        } else {
            i += 1;
        }
    }
}

fn serveLanding(arena: std.mem.Allocator, state: *const State, req: *http.Server.Request) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>PostBin</title>
        \\<style>
        \\*{box-sizing:border-box;margin:0;padding:0}
        \\body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f0f2f5;color:#333;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh}
        \\.card{background:#fff;border-radius:12px;padding:40px;text-align:center;box-shadow:0 4px 20px rgba(0,0,0,.1);max-width:500px;width:90%}
        \\h1{font-size:2.2em;color:#1a1a2e;margin-bottom:8px;font-weight:800}
        \\p{color:#888;margin-bottom:28px;font-size:.95em}
        \\button{background:#e94560;color:#fff;border:none;padding:12px 28px;border-radius:8px;font-size:1em;font-weight:600;cursor:pointer}
        \\button:hover{background:#c73652}
        \\.bins{margin-top:28px;text-align:left}
        \\.bins-title{font-size:.75em;text-transform:uppercase;color:#aaa;letter-spacing:.06em;margin-bottom:10px;font-weight:700}
        \\.bin-link{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;border-radius:6px;background:#f7f7f7;margin-bottom:6px;text-decoration:none;color:#333;font-family:monospace;font-size:.82em}
        \\.bin-link:hover{background:#eee}
        \\.bin-count{background:#e94560;color:#fff;border-radius:10px;padding:2px 8px;font-size:.75em;font-family:sans-serif;font-weight:600}
        \\</style>
        \\</head><body>
        \\<div class="card">
        \\<h1>PostBin</h1>
        \\<p>Local HTTP request inspector</p>
        \\<button onclick="window.location='/'+crypto.randomUUID()">Create New Bin</button>
    );

    // Collect unique bin IDs with request counts
    var bin_ids: std.ArrayList([]const u8) = .empty;
    var bin_counts: std.ArrayList(usize) = .empty;
    for (state.requests.items) |r| {
        var found_idx: ?usize = null;
        for (bin_ids.items, 0..) |b, bi| {
            if (std.mem.eql(u8, b, r.bin_id)) {
                found_idx = bi;
                break;
            }
        }
        if (found_idx) |bi| {
            bin_counts.items[bi] += 1;
        } else {
            try bin_ids.append(arena, r.bin_id);
            try bin_counts.append(arena, 1);
        }
    }

    if (bin_ids.items.len > 0) {
        try w.writeAll("<div class=\"bins\"><div class=\"bins-title\">Active bins</div>");
        for (bin_ids.items, 0..) |b, bi| {
            try w.print(
                "<a class=\"bin-link\" href=\"/{s}\">{s}<span class=\"bin-count\">{d}</span></a>",
                .{ b, b, bin_counts.items[bi] },
            );
        }
        try w.writeAll("</div>");
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

fn serveBinUI(arena: std.mem.Allocator, state: *const State, bin_id: []const u8, req: *http.Server.Request) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    var count: usize = 0;
    for (state.requests.items) |r| {
        if (std.mem.eql(u8, r.bin_id, bin_id)) count += 1;
    }

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
        \\.topbar a{color:#aaa;text-decoration:none;font-size:.85em}
        \\.topbar a:hover{color:#fff}
        \\.topbar h1{font-size:1.3em;font-weight:700;letter-spacing:.5px}
        \\.badge{background:#e94560;padding:3px 10px;border-radius:12px;font-size:.8em;font-weight:600}
        \\.bin-id{font-family:monospace;font-size:.75em;color:#aaa}
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
        \\<a href="/">&#8592; PostBin</a>
        \\<h1>Bin</h1>
        \\<span class="badge">{d} request{s}</span>
        \\<span class="bin-id">{s}</span>
        \\<span class="hint">auto-refresh 5 s</span>
        \\</div>
        \\<div class="container">
    , .{ count, if (count == 1) "" else "s", bin_id });

    if (count == 0) {
        try w.writeAll(
            \\<div class="empty">
            \\<h2>No requests captured yet</h2>
            \\<p>Send any HTTP request to a path under this bin:</p>
            \\<br>
            \\<code>curl -X POST http://localhost:8080/
        );
        try w.writeAll(bin_id);
        try w.writeAll("/webhook -d '{\"hello\":\"world\"}'</code></div>");
    } else {
        var i: usize = state.requests.items.len;
        while (i > 0) {
            i -= 1;
            const r = &state.requests.items[i];
            if (std.mem.eql(u8, r.bin_id, bin_id)) {
                try renderCard(w, r);
            }
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

// ---- Disk persistence ----------------------------------------------------

fn loadRequests(state: *State) !void {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        state.io,
        state.data_path,
        state.gpa,
        .unlimited,
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer state.gpa.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        const req = parseStoredRequest(state.arena, state.gpa, trimmed) catch |err| {
            std.log.warn("skipping malformed log line: {s}", .{@errorName(err)});
            continue;
        };
        try state.requests.append(state.arena, req);
        if (req.id >= state.next_id) state.next_id = req.id + 1;
    }

    // Apply per-bin cap: collect unique bin IDs then cap each
    var seen_bins: std.ArrayList([]const u8) = .empty;
    defer seen_bins.deinit(state.gpa);
    for (state.requests.items) |r| {
        var found = false;
        for (seen_bins.items) |b| {
            if (std.mem.eql(u8, b, r.bin_id)) {
                found = true;
                break;
            }
        }
        if (!found) try seen_bins.append(state.gpa, r.bin_id);
    }
    for (seen_bins.items) |b| {
        capBin(state, b);
    }
}

fn parseStoredRequest(arena: std.mem.Allocator, gpa: std.mem.Allocator, line: []const u8) !CapturedRequest {
    const parsed = try std.json.parseFromSlice(SerializedRequest, gpa, line, .{});
    defer parsed.deinit();
    const v = parsed.value;

    const b64 = std.base64.standard;
    const body_len = try b64.Decoder.calcSizeForSlice(v.body);
    const body = try arena.alloc(u8, body_len);
    try b64.Decoder.decode(body, v.body);

    const is_json = v.is_json;
    const pretty_body = if (is_json) prettyJson(arena, body) catch body else body;

    var header_list: std.ArrayList(StoredHeader) = .empty;
    for (v.headers) |h| {
        try header_list.append(arena, .{
            .name = try arena.dupe(u8, h.name),
            .value = try arena.dupe(u8, h.value),
        });
    }

    return .{
        .id = v.id,
        .bin_id = try arena.dupe(u8, v.bin_id),
        .method = try arena.dupe(u8, v.method),
        .path = try arena.dupe(u8, v.path),
        .headers = try header_list.toOwnedSlice(arena),
        .body = body,
        .pretty_body = pretty_body,
        .is_json = is_json,
    };
}

fn appendRequestToLog(state: *const State, req: *const CapturedRequest) !void {
    const b64 = std.base64.standard;
    const b64_len = b64.Encoder.calcSize(req.body.len);
    const b64_body = try state.gpa.alloc(u8, b64_len);
    defer state.gpa.free(b64_body);
    _ = b64.Encoder.encode(b64_body, req.body);

    const ser_headers = try state.gpa.alloc(SerHeader, req.headers.len);
    defer state.gpa.free(ser_headers);
    for (req.headers, 0..) |h, i| ser_headers[i] = .{ .name = h.name, .value = h.value };

    const ser = SerializedRequest{
        .id = req.id,
        .bin_id = req.bin_id,
        .method = req.method,
        .path = req.path,
        .headers = ser_headers,
        .body = b64_body,
        .is_json = req.is_json,
    };

    const json_line = try std.json.Stringify.valueAlloc(state.gpa, ser, .{});
    defer state.gpa.free(json_line);

    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(state.io, state.data_path, .{ .truncate = false });
    defer file.close(state.io);

    const file_len = try file.length(state.io);
    var write_buf: [4096]u8 = undefined;
    var fw = std.Io.File.Writer.init(file, state.io, &write_buf);
    fw.pos = file_len;
    try fw.interface.writeAll(json_line);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

// ---- Tests ---------------------------------------------------------------

const testing = std.testing;

const test_bin = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

fn testState(arena: std.mem.Allocator) State {
    return .{
        .io = std.testing.io,
        .arena = arena,
        .gpa = testing.allocator,
        .data_path = "",
    };
}

fn testRequest(state: *State, raw: []const u8) !std.Io.Writer.Allocating {
    var reader = std.Io.Reader.fixed(raw);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var srv = http.Server.init(&reader, &out.writer);
    var req = try srv.receiveHead();
    try handleRequest(state, &req);
    return out;
}

test "isValidBinId: accepts valid UUIDs" {
    try testing.expect(isValidBinId("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"));
    try testing.expect(isValidBinId("00000000-0000-4000-8000-000000000000"));
    try testing.expect(isValidBinId("f47ac10b-58cc-4372-a567-0e02b2c3d479"));
}

test "isValidBinId: rejects invalid formats" {
    try testing.expect(!isValidBinId("not-a-uuid"));
    try testing.expect(!isValidBinId("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeee")); // 35 chars
    try testing.expect(!isValidBinId("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeeee")); // 37 chars
    try testing.expect(!isValidBinId("aaaaaaaa_bbbb_4ccc_8ddd_eeeeeeeeeeee")); // underscores
    try testing.expect(!isValidBinId("gggggggg-bbbb-4ccc-8ddd-eeeeeeeeeeee")); // 'g' not hex
}

test "looksLikeJson: content-type detection" {
    try testing.expect(looksLikeJson("application/json", ""));
    try testing.expect(looksLikeJson("application/vnd.api+json", ""));
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

test "GET / returns landing page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    var out = try testRequest(&state, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const resp = out.written();
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "PostBin") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Create New Bin") != null);
}

test "GET /<uuid> returns bin UI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    var out = try testRequest(&state, "GET /" ++ test_bin ++ " HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const resp = out.written();
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, test_bin) != null);
    try testing.expect(std.mem.indexOf(u8, resp, "No requests captured yet") != null);
}

test "GET /favicon.ico returns image/x-icon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    var out = try testRequest(&state, "GET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const resp = out.written();
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, resp, "image/x-icon") != null);
}

test "non-UUID path returns 404" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    var out = try testRequest(&state, "GET /webhook HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP/1.1 404 Not Found\r\n"));
}

test "POST /<uuid>/path captures request for bin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    const raw =
        "POST /" ++ test_bin ++ "/webhook HTTP/1.1\r\n" ++
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
    try testing.expectEqualStrings("/" ++ test_bin ++ "/webhook", captured.path);
    try testing.expectEqualStrings(test_bin, captured.bin_id);
    try testing.expectEqualStrings("hello", captured.body);
}

test "POST with JSON content-type is detected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());
    const raw =
        "POST /" ++ test_bin ++ "/api HTTP/1.1\r\n" ++
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

test "bin UI only shows its own requests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = testState(arena.allocator());

    const bin_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const bin_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

    var r1 = try testRequest(&state, "POST /" ++ bin_a ++ "/x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\na");
    defer r1.deinit();
    var r2 = try testRequest(&state, "POST /" ++ bin_b ++ "/x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nb");
    defer r2.deinit();

    try testing.expectEqual(@as(usize, 2), state.requests.items.len);

    // Bin A's UI shows 1 request
    var out = try testRequest(&state, "GET /" ++ bin_a ++ " HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer out.deinit();
    const html = out.written();
    try testing.expect(std.mem.indexOf(u8, html, "1 request") != null);
    // Bin A's path appears; bin B's path does not appear in rendered cards
    try testing.expect(std.mem.indexOf(u8, html, "/" ++ bin_a ++ "/x") != null);
    try testing.expect(std.mem.indexOf(u8, html, "/" ++ bin_b ++ "/x") == null);
}
