## Unit test identitas HTTP (T-130/SEC-2): dari mana alamat IP audit diambil.
##
## Sebelum ini `X-Forwarded-For` dipakai apa adanya: klien bisa memalsukan IP di rantai audit dan
## kunci pembatas login, dan satu nilai ngawur membuat kolom `inet` menolak penulisan yang diaudit
## (transaksi bisnis ikut gagal 500).

import std/[net, options, strutils, unittest]

import ../src/identity

suite "clientIpFrom (T-130/SEC-2)":
  test "koneksi langsung: alamat socket dipakai, header diabaikan":
    # Tanpa proxy di depan, header apa pun adalah karangan klien.
    check clientIpFrom("203.0.113.9:51515", "1.2.3.4") == "203.0.113.9"
    check clientIpFrom("203.0.113.9:51515", "") == "203.0.113.9"

  test "lewat proxy loopback: header sah dipakai":
    check clientIpFrom("127.0.0.1:51515", "198.51.100.7") == "198.51.100.7"
    check clientIpFrom("127.0.0.1:1", "2001:db8::1") == "2001:db8::1"
    # Rantai dibaca dari kanan: `10.0.0.1` adalah hop yang benar-benar terhubung ke proxy kita,
    # jadi dialah klien menurut rantai ini. Entri di kirinya bisa dikarang siapa pun.
    check clientIpFrom("[::1]:51515", "198.51.100.7, 10.0.0.1") == "10.0.0.1"

  test "header tidak sah diabaikan, bukan diteruskan ke DB":
    check clientIpFrom("127.0.0.1:1", "bukan-ip") == "127.0.0.1"
    check clientIpFrom("127.0.0.1:1", "'; DROP TABLE") == "127.0.0.1"
    check clientIpFrom("127.0.0.1:1", "1.2.3.4;5") == "127.0.0.1"

  test "header kepanjangan diabaikan":
    check clientIpFrom("127.0.0.1:1", repeat('9', 60)) == "127.0.0.1"

  test "IPv6 berkurung dan berport dinormalkan":
    check clientIpFrom("[2001:db8::1]:9000", "") == "2001:db8::1"

suite "peer tepercaya dari rentang CIDR (KRAN_TRUSTED_PROXY_CIDRS)":
  let bridge = initTrustedProxies("10.89.0.0/16")

  test "tanpa rentang, peer gateway diperlakukan sebagai klien biasa":
    # Bentuk qouver: Caddy di host, API di container podman, jadi peer adalah alamat gateway
    # bridge. Tanpa rentang tepercaya, header tidak dibaca dan SEMUA klien tampak satu IP.
    check clientIpFrom("10.89.0.1:41234", "198.51.100.7") == "10.89.0.1"

  test "default bawaan tidak mempercayai jaringan bersama (K-02)":
    # Jaringan `qouver` dipakai bersama sds-api dan majadu-api: tetangga bisa menghubungi IP
    # container ini langsung, jadi mempercayai seluruh 10.88/10.89/10.90 berarti tetangga boleh
    # memalsukan IP audit dan merotasi kunci pembatas login. Default kosong = gagal tertutup.
    const tanpaEnv = TrustedProxySet()
    for peer in ["10.88.0.9:1234", "10.89.0.9:1234", "10.90.0.9:1234"]:
      check clientIpFrom(peer, "198.51.100.7", tanpaEnv) == withoutPort(peer)
      check not isTrustedPeer(withoutPort(peer), tanpaEnv)

  test "satu gateway /32 adalah bentuk yang dianjurkan: tetangga tidak ikut tepercaya":
    let gateway = initTrustedProxies("10.89.0.1/32")
    check gateway.len == 1
    check clientIpFrom("10.89.0.1:41234", "198.51.100.7", gateway) == "198.51.100.7"
    # Tetangga di jaringan yang sama tetap ditolak: yang tepercaya adalah proxy, bukan subnet.
    check clientIpFrom("10.89.0.9:41234", "198.51.100.7", gateway) == "10.89.0.9"

  test "dengan rentang, peer gateway boleh dipercaya":
    check clientIpFrom("10.89.0.1:41234", "198.51.100.7", bridge) == "198.51.100.7"
    # Di luar rentang tetap tidak dipercaya: rentang yang salah tidak melebarkan kepercayaan.
    check clientIpFrom("10.90.0.1:41234", "198.51.100.7", bridge) == "10.90.0.1"

  test "rantai dibaca dari kanan: entri paling kiri tidak bisa dikarang klien":
    # Klien mengirim `X-Forwarded-For: 1.2.3.4`; Caddy menambahkan peer sebenarnya di kanan.
    check clientIpFrom("127.0.0.1:1", "1.2.3.4, 198.51.100.7", bridge) == "198.51.100.7"
    # Dua proxy tepercaya berturut-turut: lewati keduanya, ambil klien sesungguhnya.
    check clientIpFrom("127.0.0.1:1", "1.2.3.4, 10.89.0.9, 10.89.0.1", bridge) == "1.2.3.4"

  test "entri tidak sah di rantai dilewati, bukan membatalkan seluruh header":
    check clientIpFrom("127.0.0.1:1", "bukan-ip, 198.51.100.7", bridge) == "198.51.100.7"
    check clientIpFrom("127.0.0.1:1", "1.2.3.4, bukan-ip", bridge) == "1.2.3.4"

  test "rentang tidak sah dilewati; loopback tetap tepercaya":
    check parseCidr("bukan-cidr").isNone
    check parseCidr("10.89.0.0/99").isNone
    check parseCidr("").isNone
    # Entri rusak di daftar tidak menular ke entri yang sah.
    let campur = initTrustedProxies("bukan-cidr, 10.89.0.0/16")
    check campur.len == 1
    check clientIpFrom("10.89.0.1:1", "198.51.100.7", campur) == "198.51.100.7"
    # Loopback tidak perlu dikonfigurasi: dev (Vite proxy) dan test berjalan di host yang sama.
    check clientIpFrom("127.0.0.1:1", "198.51.100.7", TrustedProxySet()) == "198.51.100.7"

  test "CIDR IPv6 dan tanpa prefix":
    let v6 = initTrustedProxies("::1/128, 2001:db8::/32")
    check clientIpFrom("[2001:db8::5]:1", "198.51.100.7", v6) == "198.51.100.7"
    check clientIpFrom("[2001:dc8::5]:1", "198.51.100.7", v6) == "2001:dc8::5"
    let tunggal = initTrustedProxies("127.0.0.1")
    check tunggal.len == 1
    check tunggal.toSeq()[0].prefix == 32

  test "keluarga alamat berbeda tidak pernah cocok":
    let v4 = initTrustedProxies("10.0.0.0/8")
    var v6: IpAddress
    v6 = parseIpAddress("::ffff:10.0.0.1")
    check not isTrustedPeer("::ffff:10.0.0.1", v4)
