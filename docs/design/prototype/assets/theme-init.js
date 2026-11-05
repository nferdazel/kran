/* Applies the stored theme and language before first paint. */
(function () {
  "use strict";

  var theme = null;
  var locale = null;

  try {
    theme = window.localStorage.getItem("kran.theme");
    locale = window.localStorage.getItem("kran.locale");
  } catch (error) {
    theme = null;
    locale = null;
  }

  if (theme !== "light" && theme !== "dark") {
    theme =
      window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light";
  }

  if (locale !== "id" && locale !== "en") {
    locale = "id";
  }

  document.documentElement.setAttribute("data-theme", theme);
  document.documentElement.lang = locale === "en" ? "en-US" : "id-ID";
})();
