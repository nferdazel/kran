import mummy, mummy/routers

const body = """{"status":"ok"}"""

proc ping(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, body)

proc events(request: Request) =
  # Mummy 0.4.8: tidak ada API untuk streaming/chunked response (respons dikirim
  # utuh dari memori). Endpoint ini sengaja mengembalikan 501 sebagai bukti.
  var headers: HttpHeaders
  headers["Content-Type"] = "application/problem+json"
  request.respond(501, headers,
    """{"code":"CBS-9001","detail":"mummy 0.4.8 tidak mendukung streaming/SSE"}""")

var router: Router
router.get("/api/v1/ping", ping)
router.get("/api/v1/events/stream", events)

let server = newServer(router)
echo "mummy listening on 8081"
server.serve(Port(8081))
