import prologue

proc ping(ctx: Context) {.async.} =
  ctx.response.headers["Content-Type"] = "application/json"
  resp """{"status":"ok"}"""

let app = newApp(settings = newSettings(port = Port(8082)))
app.get("/api/v1/ping", ping)
echo "prologue listening on 8082"
app.run()
