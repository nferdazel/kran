## Batas waktu blok kerja DB (T-065) — tanpa DB nyata.
##
## Yang dibuktikan: pendaftaran `(fd, batas)` benar-benar memutus soket saat batas lewat, dan
## `disarmDeadline` melaporkan kejadian itu supaya pemanggil membuang koneksinya. Perilaku kueri
## sesungguhnya (koneksi beku lewat perantara TCP) diuji di `itpool.nim`.

import std/[net, os, unittest]

import "platform-lib/db/deadline"

proc pair(): (Socket, Socket) =
  ## Sepasang soket TCP terhubung lewat loopback.
  let srv = newSocket()
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(Port(0), "127.0.0.1")
  srv.listen()
  let client = newSocket()
  client.connect("127.0.0.1", srv.getLocalAddr()[1])
  var accepted: Socket
  srv.accept(accepted)
  srv.close()
  (client, accepted)

suite "deadline: batas blok kerja":
  test "batas lewat -> soket diputus dan disarm melaporkan fired":
    let (client, server) = pair()
    defer:
      client.close()
      server.close()
    let g = armDeadline(int32(client.getFd()), 100)
    check g.token != 0
    sleep(400)
    check disarmDeadline(g)
    # shutdown(SHUT_RDWR) -> recv melihat EOF, bukan menggantung.
    check client.recv(1).len == 0

  test "disarm sebelum batas -> false dan soket tetap hidup":
    let (client, server) = pair()
    defer:
      client.close()
      server.close()
    let g = armDeadline(int32(client.getFd()), 30_000)
    check g.token != 0
    check not disarmDeadline(g)
    sleep(200)
    # Socket masih bisa dipakai: kirim dari server, terima di klien.
    server.send("x")
    check client.recv(1) == "x"

  test "tanpa batas (fd/batas tidak valid) -> guard kosong, disarm false":
    check armDeadline(-1, 100).token == 0
    check armDeadline(int32(1), 0).token == 0
    check not disarmDeadline(DeadlineGuard(token: 0))
