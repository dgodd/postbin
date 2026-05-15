# postbin

A local HTTP request inspector written in Zig 0.16. Send any HTTP request to it and inspect the captured headers and body in a web UI — like [requestbin](https://requestbin.com) but running on your machine.

## Features

- Captures any HTTP request (POST, PUT, PATCH, DELETE, etc.) to any path
- Pretty-prints JSON bodies with syntax highlighting
- Shows all request headers in a clean grid layout
- Web UI at `GET /` auto-refreshes every 5 seconds
- Also logs each request to the terminal with headers and body preview
- Color-coded method badges (GET/POST/PUT/DELETE/PATCH)
- `Access-Control-Allow-Origin: *` on capture responses (CORS-friendly)

## Build

Requires Zig 0.16.

```sh
zig build
```

The binary is written to `zig-out/bin/postbin`.

## Run

```sh
zig build run
# or
./zig-out/bin/postbin
```

Listens on `http://localhost:8080/`.

## Usage

Open `http://localhost:8080/` in a browser. Send requests to any other path:

```sh
# JSON body — auto-detected and pretty-printed
curl -X POST http://localhost:8080/api/login \
  -H 'Content-Type: application/json' \
  -d '{"user":"alice","pass":"secret"}'

# Plain text
curl -X POST http://localhost:8080/webhook \
  -d 'plain body here'

# Custom headers
curl -X PUT http://localhost:8080/items/42 \
  -H 'Authorization: Bearer token123' \
  -H 'Content-Type: application/json' \
  -d '[1,2,3]'

# Delete, patch, etc.
curl -X DELETE http://localhost:8080/items/42
curl -X PATCH http://localhost:8080/user -d '{"name":"bob"}'
```

Requests accumulate in memory for the lifetime of the process. `GET /` always shows the UI — it is not captured.

## Limits

- Body cap: 4 MB per request
- Storage: in-memory only, lost on restart
- Single-threaded: connections are handled sequentially
