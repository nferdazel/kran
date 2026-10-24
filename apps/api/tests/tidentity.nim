## Unit test identitas HTTP (T-130/SEC-2): dari mana alamat IP audit diambil.
##
## Sebelum ini `X-Forwarded-For` dipakai apa adanya: klien bisa memalsukan IP di rantai audit dan
## kunci pembatas login, dan satu nilai ngawur membuat kolom `inet` menolak penulisan yang diaudit
## (transaksi bisnis ikut gagal 500).

import std/[strutils, unittest]

import ../src/identity

suite "clientIpFrom (T-130/SEC-2)":
  test "koneksi langsung: alamat socket dipakai, header diabaikan":
    # Tanpa proxy di depan, header apa pun adalah karangan klien.
    check clientIpFrom("203.0.113.9:51515", "1.2.3.4") == "203.0.113.9"
    check clientIpFrom("203.0.113.9:51515", "") == "203.0.113.9"

  test "lewat proxy loopback: header sah dipakai":
    check clientIpFrom("127.0.0.1:51515", "198.51.100.7") == "198.51.100.7"
    check clientIpFrom("[::1]:51515", "198.51.100.7, 10.0.0.1") == "198.51.100.7"
    check clientIpFrom("127.0.0.1:1", "2001:db8::1") == "2001:db8::1"

  test "header tidak sah diabaikan, bukan diteruskan ke DB":
    check clientIpFrom("127.0.0.1:1", "bukan-ip") == "127.0.0.1"
    check clientIpFrom("127.0.0.1:1", "'; DROP TABLE") == "127.0.0.1"
    check clientIpFrom("127.0.0.1:1", "1.2.3.4;5") == "127.0.0.1"

  test "header kepanjangan diabaikan":
    check clientIpFrom("127.0.0.1:1", repeat('9', 60)) == "127.0.0.1"

  test "IPv6 berkurung dan berport dinormalkan":
    check clientIpFrom("[2001:db8::1]:9000", "") == "2001:db8::1"
