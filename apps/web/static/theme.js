// Tema sebelum render (spec §15.3) — mencegah flash terang di mode gelap.
//
// Berkas ini **bukan** skrip inline di `app.html` karena CSP: Kit hanya menerbitkan hash untuk script
// yang ia hasilkan sendiri, sehingga script inline buatan kita akan diblokir oleh
// `script-src 'self' 'sha256-…'` (O-061 / D-045). Sebagai berkas aset, ia lolos `'self'` tanpa
// melonggarkan CSP.
//
// Kunci localStorage: `kran-theme` = "light" | "dark" | "system".
(function () {
  try {
    var stored = localStorage.getItem("kran-theme");
    var dark =
      stored === "dark" ||
      ((stored === null || stored === "system") &&
        window.matchMedia("(prefers-color-scheme: dark)").matches);
    var theme = dark ? "dark" : "light";
    var root = document.documentElement;
    root.setAttribute("data-theme", theme);
    root.style.colorScheme = theme;
  } catch (e) {
    /* localStorage bisa diblokir; biarkan tema default. */
  }
})();
