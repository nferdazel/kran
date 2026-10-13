import std/unittest

import ../api

suite "modul hello (scaffold)":
  test "greet menyapa":
    check greet("Dunia") == "Halo, Dunia!"

  test "use case memanggil domain":
    check greetUser("Dunia") == "Halo, Dunia!"
