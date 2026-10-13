import std/[asyncdispatch, asyncnet, strutils, net]

const body = """{"status":"ok"}"""

proc sendPlain(client: AsyncSocket, status, ctype, payload: string) {.async.} =
  await client.send("HTTP/1.1 " & status & "\r\nContent-Type: " & ctype &
    "\r\nContent-Length: " & $payload.len & "\r\nConnection: close\r\n\r\n" & payload)

proc handleSse(client: AsyncSocket) {.async.} =
  await client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
    "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n")
  var i = 0
  while true:
    await client.send("id: " & $i & "\ndata: {\"n\":" & $i & "}\n\n")
    inc i
    await sleepAsync(200)

proc handle(client: AsyncSocket) {.async.} =
  let requestLine = await client.recvLine()
  let parts = requestLine.split(' ')
  if parts.len < 2:
    client.close()
    return
  case parts[1]
  of "/api/v1/ping":
    await sendPlain(client, "200 OK", "application/json", body)
  of "/api/v1/events/stream":
    await handleSse(client)
  else:
    await sendPlain(client, "404 Not Found", "application/problem+json",
      """{"code":"CBS-0001","i18nKey":"error.notFound"}""")
  if parts[1] != "/api/v1/events/stream":
    await sleepAsync(5)
    client.close()

proc main() {.async.} =
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(8083))
  server.listen()
  echo "asyncnet2 listening on 8083"
  while true:
    let client = await server.accept()
    asyncCheck handle(client)

waitFor main()
