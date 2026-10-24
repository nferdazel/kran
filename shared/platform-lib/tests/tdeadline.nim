## Batas waktu blok kerja DB (T-065) — tanpa DB nyata.
##
## Yang dibuktikan: pendaftaran `(fd, batas)` benar-benar memutus soket saat batas lewat, dan
## `disarmDeadline` melaporkan kejadian itu supaya pemanggil membuang koneksinya. Perilaku kueri
## sesungguhnya (koneksi beku lewat perantara TCP) diuji di `itpool.nim`.

import std/[net, os, strutils, unittest]

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

suite "deadline: degradasi tidak senyap (T-066)":
  test "tabel penuh -> token 0, penghitung naik, log terstruktur sekali":
    var lines: seq[string]
    # `cast(gcsafe)` hanya di test: closure menulis ke variabel global seq, sedangkan `LogSink`
    # diwajibkan gcsafe karena dipakai lintas thread pemantau.
    setDeadlineLogSink(proc(line: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        lines.add(line))
    defer:
      setDeadlineLogSink(nil)

    let before = deadlineUnarmedTotal()
    var guards: seq[DeadlineGuard]
    while guards.len <= maxGuards:
      let g = armDeadline(int32(1), 60_000)
      if g.token == 0:
        break
      guards.add(g)

    check guards.len == maxGuards
    check deadlineUnarmedTotal() == before + 1
    check lines.len == 1
    check lines[0].contains("\"cause\":\"slot_table_full\"")
    check lines[0].contains("\"deadline_unarmed_total\"")

    # Kejadian berikutnya menambah penghitung tetapi tidak menulis log lagi.
    check armDeadline(int32(1), 60_000).token == 0
    check deadlineUnarmedTotal() == before + 2
    check lines.len == 1

    for g in guards:
      discard disarmDeadline(g)
