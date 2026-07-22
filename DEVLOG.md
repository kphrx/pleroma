# Development Log

## Gun pool validation

- The previous unique origin registry forced concurrent HTTP/1 requests onto one connection.
- Pool identity omitted proxy routes and credentials, allowing incompatible routes to reuse a connection.
- Gun 2.2 CONNECT requests require their tunnel stream reference on subsequent requests; Tesla's bundled Gun adapter does not preserve it.
- CONNECT and SOCKS5 setup returned before the destination tunnel was ready and did not pass authentication credentials.
- The existing global `max_connections` limit and idle reclaimer bound HTTP/1 sibling and many-host connection growth.
- SOCKS4 is not supported by Gun 2.2 and is now rejected explicitly by the Gun adapter.
- Gun reports a stale stream error to the process that calls `cancel/2`; pool workers must consume that reply so one HTTP/2 cancellation cannot terminate other multiplexed requests.
- Streamed uploads must be registered before body enumeration and cancelled if enumeration exits, throws, or raises, otherwise a partial HTTP/1 request can remain reusable.
- Gun 2.4 bounds HTTP/1 response header and trailer buffers, rejects invalid request headers by default, and fixes cross-origin HTTP/2 push handling; Gun 2.4.1 includes Cowlib 2.17.1 to repair HTTP/2 HPACK decoding.
- Plain HTTP proxy requests must use absolute-form request targets; CONNECT is reserved for HTTPS tunnels because forwarding proxies commonly reject CONNECT to port 80.
