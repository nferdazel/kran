/* Behaviour for the transaction screens.
 * Plain ES2020, no modules, so the prototype works from file://. */
(function () {
  "use strict";

  var renderers = [];

  function $(selector, root) {
    return (root || document).querySelector(selector);
  }

  function $all(selector, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(selector));
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    if (typeof text === "string") {
      node.textContent = text;
    }
    return node;
  }

  function localeTag() {
    return document.documentElement.lang.indexOf("en") === 0 ? "en-US" : "id-ID";
  }

  function localeCode() {
    return document.documentElement.lang.indexOf("en") === 0 ? "en" : "id";
  }

  function t(key, vars) {
    var extra = window.KRAN_EXTRA_I18N || {};
    var source = extra[localeCode()] || {};
    var fallback = extra.id || {};
    var text = Object.prototype.hasOwnProperty.call(source, key) ? source[key] : fallback[key];
    if (typeof text !== "string") {
      return key;
    }
    if (vars) {
      Object.keys(vars).forEach(function (name) {
        text = text.split("{" + name + "}").join(String(vars[name]));
      });
    }
    return text;
  }

  function formatMoney(cents) {
    var value = typeof cents === "bigint" ? cents : 0n;
    var negative = value < 0n;
    var absolute = negative ? -value : value;
    var whole = absolute / 100n;
    var fraction = (absolute % 100n).toString().padStart(2, "0");
    var grouped = new Intl.NumberFormat(localeTag(), {
      useGrouping: true,
      maximumFractionDigits: 0
    }).format(whole);
    return (negative ? "-" : "") + grouped + (localeCode() === "en" ? "." : ",") + fraction;
  }

  function parseMoney(raw) {
    if (raw === null || raw === undefined) {
      return null;
    }
    var source = String(raw).trim().replace(/\s/g, "");
    if (!/^\d+(?:[.,]\d{0,2})?$/.test(source)) {
      return null;
    }
    var parts = source.split(/[.,]/);
    var whole = parts[0] || "0";
    var fraction = ((parts[1] || "") + "00").slice(0, 2);
    return BigInt(whole) * 100n + BigInt(fraction);
  }

  function sanitizeAmount(value) {
    var cleaned = value.replace(/[^\d.,]/g, "");
    var separator = cleaned.search(/[.,]/);
    if (separator >= 0) {
      cleaned = cleaned.slice(0, separator + 1) + cleaned.slice(separator + 1).replace(/[.,]/g, "");
    }
    return cleaned;
  }

  function formatBusinessDate() {
    return new Intl.DateTimeFormat(localeTag(), {
      day: "numeric",
      month: "short",
      year: "numeric",
      timeZone: "Asia/Jakarta"
    }).format(new Date("2026-11-05T00:00:00+07:00"));
  }

  function formatTime(date) {
    var parts = new Intl.DateTimeFormat(localeTag(), {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
      timeZone: "Asia/Jakarta"
    }).formatToParts(date);
    var hour = "";
    var minute = "";
    parts.forEach(function (part) {
      if (part.type === "hour") {
        hour = part.value;
      } else if (part.type === "minute") {
        minute = part.value;
      }
    });
    return hour + ":" + minute + " WIB";
  }

  function announce(message) {
    var live = document.getElementById("live");
    if (!live) {
      return;
    }
    live.textContent = "";
    window.requestAnimationFrame(function () {
      live.textContent = message;
    });
  }

  function setText(node, key, vars) {
    if (node) {
      node.textContent = t(key, vars);
    }
  }

  function setFieldError(input, errorNode, key, focus) {
    if (input) {
      input.setAttribute("aria-invalid", "true");
    }
    if (errorNode) {
      errorNode.textContent = t(key);
      errorNode.hidden = false;
    }
    if (focus && input) {
      input.focus();
    }
  }

  function clearFieldError(input, errorNode) {
    if (input) {
      input.removeAttribute("aria-invalid");
    }
    if (errorNode) {
      errorNode.hidden = true;
      errorNode.textContent = "";
    }
  }

  function copyText(value) {
    function fallback() {
      try {
        var area = document.createElement("textarea");
        area.value = value;
        area.setAttribute("readonly", "true");
        area.className = "sr-only";
        document.body.appendChild(area);
        area.select();
        var ok = document.execCommand("copy");
        document.body.removeChild(area);
        announce(t(ok ? "common.copied" : "common.copyFailed"));
      } catch (error) {
        announce(t("common.copyFailed"));
      }
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(function () {
        announce(t("common.copied"));
      }, fallback);
    } else {
      fallback();
    }
  }

  function initCopyButtons() {
    document.addEventListener("click", function (event) {
      var target = event.target;
      if (!(target instanceof Element)) {
        return;
      }
      var button = target.closest("[data-tx-copy]");
      if (!button) {
        return;
      }
      var source = document.querySelector(button.getAttribute("data-tx-copy"));
      if (source) {
        copyText(source.textContent.trim());
      }
    });
  }

  function initLocaleRefresh() {
    document.addEventListener("click", function (event) {
      var target = event.target;
      if (!(target instanceof Element) || !target.closest("[data-locale-set]")) {
        return;
      }
      window.setTimeout(function () {
        renderers.forEach(function (render) {
          render();
        });
      }, 0);
    });
  }

  function buildReceipt(titleKey, rows, footerKey) {
    var receipt = el("div", "receipt");
    var head = el("div", "receipt__head");
    head.appendChild(el("p", "receipt__title", t(titleKey)));
    head.appendChild(el("p", "receipt__meta", "KRAN · " + t("kas.branchValue")));
    receipt.appendChild(head);

    var list = el("dl", "receipt__rows");
    rows.forEach(function (row) {
      var line = el("div", "receipt__row");
      line.appendChild(el("dt", "", t(row.label)));
      line.appendChild(el("dd", row.money ? "money" : "", row.value));
      list.appendChild(line);
    });
    receipt.appendChild(list);

    if (footerKey) {
      var foot = el("div", "receipt__foot");
      foot.appendChild(el("p", "", t(footerKey)));
      receipt.appendChild(foot);
    }
    return receipt;
  }

  function printNode(node) {
    var area = document.getElementById("print-receipt");
    if (!node || !area) {
      return;
    }
    var clone = node.cloneNode(true);
    $all("[id]", clone).forEach(function (item) {
      item.removeAttribute("id");
    });
    $all("button", clone).forEach(function (button) {
      button.remove();
    });
    area.replaceChildren(clone);
    document.body.classList.add("print-receipt-mode");
    window.print();
  }

  window.addEventListener("afterprint", function () {
    document.body.classList.remove("print-receipt-mode");
  });

  /* ------------------------------------------------------------------ */
  /* Login                                                              */
  /* ------------------------------------------------------------------ */

  function initLogin() {
    var form = $("#login-form");
    if (!form) {
      return;
    }

    var username = $("#login-username");
    var password = $("#login-password");
    var branch = $("#login-branch");
    var submit = $("#login-submit");
    var submitLabel = $("#login-submit-label");
    var spinner = $("#login-spinner");
    var alertBox = $("#login-alert");
    var alertTitle = $("#login-alert-title");
    var alertBody = $("#login-alert-body");
    var usernameError = $("#login-username-error");
    var passwordError = $("#login-password-error");
    var capsHint = $("#login-caps");
    var stateSelect = $("#login-state");

    var state = "normal";
    var busy = false;
    var attempts = 0;
    var alertKeys = null;
    var fieldErrors = { username: null, password: null };

    function currentAlert() {
      if (!alertKeys || alertBox.hidden) {
        return;
      }
      alertTitle.textContent = t(alertKeys.title);
      alertBody.textContent = alertKeys.body ? t(alertKeys.body) : "";
      alertBody.hidden = !alertKeys.body;
    }

    function showAlert(titleKey, bodyKey) {
      alertKeys = { title: titleKey, body: bodyKey || null };
      alertBox.hidden = false;
      currentAlert();
    }

    function hideAlert() {
      alertKeys = null;
      alertBox.hidden = true;
    }

    function applyFieldErrors() {
      if (fieldErrors.username) {
        usernameError.textContent = t(fieldErrors.username);
        usernameError.hidden = false;
      }
      if (fieldErrors.password) {
        passwordError.textContent = t(fieldErrors.password);
        passwordError.hidden = false;
      }
    }

    function clearErrors() {
      fieldErrors = { username: null, password: null };
      clearFieldError(username, usernameError);
      clearFieldError(password, passwordError);
    }

    function setBusy(next) {
      busy = next;
      var locked = state === "locked";
      submit.setAttribute("aria-busy", String(next));
      spinner.hidden = !next;
      submitLabel.textContent = t(next ? "login.actionBusy" : "login.action");
      [username, password, branch].forEach(function (field) {
        field.disabled = next || locked;
      });
      submit.disabled = next || locked;
    }

    function applyState(next) {
      state = next;
      if (stateSelect) {
        stateSelect.value = next;
      }
      hideAlert();
      clearErrors();
      setBusy(false);
      if (next === "loading") {
        setBusy(true);
      } else if (next === "error") {
        showAlert("login.error.invalidTitle", "login.error.invalid");
      } else if (next === "locked") {
        showAlert("login.error.lockedTitle", "login.error.locked");
        setBusy(false);
      } else {
        attempts = 0;
      }
    }

    function updateCaps(event) {
      if (!capsHint || !event.getModifierState) {
        return;
      }
      capsHint.hidden = !event.getModifierState("CapsLock");
    }

    function render() {
      if (busy) {
        submitLabel.textContent = t("login.actionBusy");
      } else {
        submitLabel.textContent = t("login.action");
      }
      currentAlert();
      applyFieldErrors();
    }

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (busy || state === "locked") {
        return;
      }
      hideAlert();
      clearErrors();

      var invalid = null;
      if (!username.value.trim()) {
        fieldErrors.username = "login.error.usernameRequired";
        setFieldError(username, usernameError, "login.error.usernameRequired");
        invalid = invalid || username;
      }
      if (!password.value) {
        fieldErrors.password = "login.error.passwordRequired";
        setFieldError(password, passwordError, "login.error.passwordRequired");
        invalid = invalid || password;
      }
      if (invalid) {
        showAlert("common.formSummary", null);
        announce(t("common.formSummary"));
        invalid.focus();
        return;
      }

      attempts += 1;
      setBusy(true);
      window.setTimeout(function () {
        setBusy(false);
        if (state === "locked") {
          return;
        }
        if (attempts >= 3) {
          applyState("locked");
          announce(t("login.error.locked"));
          return;
        }
        state = "error";
        if (stateSelect) {
          stateSelect.value = "error";
        }
        showAlert("login.error.invalidTitle", "login.error.invalid");
        announce(t("login.error.invalid"));
        username.focus();
      }, 700);
    });

    username.addEventListener("input", function () {
      fieldErrors.username = null;
      clearFieldError(username, usernameError);
    });

    password.addEventListener("input", function () {
      fieldErrors.password = null;
      clearFieldError(password, passwordError);
    });

    password.addEventListener("keydown", updateCaps);
    password.addEventListener("keyup", updateCaps);
    password.addEventListener("blur", function () {
      if (capsHint) {
        capsHint.hidden = true;
      }
    });

    if (stateSelect) {
      stateSelect.addEventListener("change", function () {
        applyState(stateSelect.value);
      });
    }

    renderers.push(render);
    render();

    window.requestAnimationFrame(function () {
      username.focus();
    });
  }

  /* ------------------------------------------------------------------ */
  /* Transfer                                                           */
  /* ------------------------------------------------------------------ */

  function initTransfer() {
    var work = $("#transfer-work");
    if (!work) {
      return;
    }

    var denied = $("#transfer-denied");
    var lockedBanner = $("#transfer-locked-banner");
    var sourceForm = $("#transfer-form");
    var destForm = $("#transfer-destination-form");
    var detailsForm = $("#transfer-details-form");
    var sourceInput = $("#transfer-source");
    var destInput = $("#transfer-dest");
    var sourceLoad = $("#transfer-source-load");
    var destLoad = $("#transfer-dest-load");
    var sourceStatus = $("#transfer-source-status");
    var destStatus = $("#transfer-dest-status");
    var sourceError = $("#transfer-source-error");
    var destError = $("#transfer-dest-error");
    var sourceIdentity = $("#transfer-source-identity");
    var destIdentity = $("#transfer-dest-identity");
    var sourceLoaded = $("#transfer-source-loaded");
    var destVerified = $("#transfer-dest-verified");
    var amountInput = $("#transfer-amount");
    var amountPreview = $("#transfer-amount-preview");
    var amountError = $("#transfer-amount-error");
    var narration = $("#transfer-narration");
    var referenceInput = $("#transfer-reference");
    var summary = $("#transfer-summary");
    var reviewTitle = $("#transfer-review-title");
    var reviewEmpty = $("#transfer-review-empty");
    var reviewFilled = $("#transfer-review-filled");
    var reviewBlocked = $("#transfer-review-blocked");
    var reviewError = $("#transfer-review-error");
    var reviewSuccess = $("#transfer-review-success");
    var blockedReason = $("#transfer-blocked-reason");
    var errorTitle = $("#transfer-error-title");
    var errorBody = $("#transfer-error-body");
    var errorRef = $("#transfer-error-ref");
    var checkStatus = $("#transfer-check-status");
    var successBody = $("#transfer-success-body");
    var receiptSlot = $("#transfer-receipt-slot");
    var reviewOpen = $("#transfer-review-open");
    var reviewSubmit = $("#transfer-review-submit");
    var submitSpinner = $("#transfer-submit-spinner");
    var stateSelect = $("#transfer-state");

    var stateMode = "normal";
    var source = null;
    var dest = null;
    var panel = "empty";
    var busy = false;
    var lookupToken = 0;
    var refSequence = 130;
    var reference = "TRX-000130";
    var lastSaved = null;
    var blockedKey = null;
    var errorInfo = null;
    var statusKeys = {
      source: { key: "transfer.sourceStatusEmpty", vars: null },
      dest: { key: "transfer.destEmpty", vars: null }
    };

    var DEMO_SOURCE = "0000000001";
    var DEMO_DEST = "0000000002";

    function accountFor(number) {
      return { no: number, holderMissing: false };
    }

    function nextReference() {
      refSequence += 1;
      return "TRX-" + String(refSequence).padStart(6, "0");
    }

    function renderReference() {
      if (referenceInput) {
        referenceInput.value = reference;
      }
      var reviewRef = $("#transfer-review-ref");
      if (reviewRef) {
        reviewRef.textContent = panel === "success" && lastSaved ? lastSaved.ref : reference;
      }
    }

    function setStatus(kind, key, vars) {
      statusKeys[kind] = { key: key, vars: vars || null };
      var node = kind === "source" ? sourceStatus : destStatus;
      if (node) {
        node.textContent = t(key, vars);
      }
    }

    function renderStatuses() {
      if (sourceStatus) {
        sourceStatus.textContent = t(statusKeys.source.key, statusKeys.source.vars);
      }
      if (destStatus) {
        destStatus.textContent = t(statusKeys.dest.key, statusKeys.dest.vars);
      }
    }

    function renderIdentity(kind) {
      var account = kind === "source" ? source : dest;
      var container = kind === "source" ? sourceIdentity : destIdentity;
      if (!container) {
        return;
      }
      if (!account) {
        container.hidden = true;
        return;
      }
      container.hidden = false;
      var prefix = "#transfer-" + (kind === "source" ? "source" : "dest") + "-";
      setText($(prefix + "holder"), account.holderMissing ? "tx.valueUnavailable" : "ph.member");
      setText($(prefix + "member"), account.holderMissing ? "tx.valueUnavailable" : "ph.memberNo");
      var numberNode = $(prefix + "no");
      if (numberNode) {
        numberNode.textContent = account.no;
      }
      setText($(prefix + "product"), "tx.productVoluntary");
      setText($(prefix + "branch"), "kas.branchValue");
      setText($(prefix + "status"), account.holderMissing ? "tx.valueUnavailable" : "tx.statusActive");
      var badge = $(prefix + "badge");
      if (badge) {
        badge.textContent = t(account.holderMissing ? "tx.valueUnavailable" : "tx.statusActive");
        badge.className = "badge " + (account.holderMissing ? "badge--warning" : "badge--success");
      }
      if (kind === "source" && sourceLoaded) {
        sourceLoaded.hidden = false;
      }
      if (kind === "dest" && destVerified) {
        destVerified.hidden = account.holderMissing;
      }
    }

    function renderAmountPreview() {
      if (!amountPreview) {
        return;
      }
      var cents = parseMoney(amountInput.value);
      amountPreview.textContent = cents !== null && cents > 0n ? formatMoney(cents) : "";
    }

    function showPanel(name) {
      panel = name;
      reviewEmpty.hidden = name !== "empty";
      reviewFilled.hidden = name !== "filled";
      reviewBlocked.hidden = name !== "blocked";
      reviewError.hidden = name !== "error";
      reviewSuccess.hidden = name !== "success";
    }

    function hideSummary() {
      if (summary) {
        summary.hidden = true;
        summary.textContent = "";
      }
    }

    function showSummary() {
      if (summary) {
        summary.textContent = t("common.formSummary");
        summary.hidden = false;
      }
    }

    function clearFormErrors() {
      clearFieldError(sourceInput, sourceError);
      clearFieldError(destInput, destError);
      clearFieldError(amountInput, amountError);
      hideSummary();
    }

    function fillReview(cents) {
      if (!source || !dest) {
        return;
      }
      setText($("#transfer-review-from-holder"), source.holderMissing ? "tx.valueUnavailable" : "ph.member");
      setText($("#transfer-review-from-member"), source.holderMissing ? "tx.valueUnavailable" : "ph.memberNo");
      setText($("#transfer-review-from-branch"), "kas.branchValue");
      setText($("#transfer-review-from-product"), "tx.productVoluntary");
      setText($("#transfer-review-from-status"), source.holderMissing ? "tx.valueUnavailable" : "tx.statusActive");
      var fromNo = $("#transfer-review-from-no");
      if (fromNo) {
        fromNo.textContent = source.no;
      }

      setText($("#transfer-review-to-holder"), dest.holderMissing ? "tx.valueUnavailable" : "ph.member");
      setText($("#transfer-review-to-member"), dest.holderMissing ? "tx.valueUnavailable" : "ph.memberNo");
      setText($("#transfer-review-to-branch"), "kas.branchValue");
      setText($("#transfer-review-to-product"), "tx.productVoluntary");
      setText($("#transfer-review-to-status"), dest.holderMissing ? "tx.valueUnavailable" : "tx.statusActive");
      var toNo = $("#transfer-review-to-no");
      if (toNo) {
        toNo.textContent = dest.no;
      }

      var amountNode = $("#transfer-review-amount");
      if (amountNode) {
        amountNode.textContent = formatMoney(cents);
      }
      var noteNode = $("#transfer-review-note");
      if (noteNode) {
        noteNode.textContent = narration.value.trim() || t("common.none");
      }
      renderReference();
    }

    function showBlocked(key, focus) {
      blockedKey = key;
      blockedReason.textContent = t(key);
      showPanel("blocked");
      if (focus !== false) {
        reviewTitle.focus();
      }
    }

    function showError(titleKey, bodyKey, vars, canCheck, focus) {
      errorInfo = { title: titleKey, body: bodyKey, vars: vars || null, check: Boolean(canCheck) };
      errorTitle.textContent = t(titleKey);
      errorBody.textContent = t(bodyKey, vars);
      errorRef.textContent = reference;
      checkStatus.hidden = !canCheck;
      showPanel("error");
      if (focus !== false) {
        reviewTitle.focus();
      }
    }

    function buildTransferReceipt(saved) {
      return buildReceipt(
        "transfer.receiptTitle",
        [
          { label: "transfer.receiptDate", value: formatBusinessDate() },
          { label: "transfer.receiptTime", value: saved.time },
          { label: "transfer.receiptFrom", value: saved.fromNo },
          { label: "transfer.receiptTo", value: saved.toNo },
          { label: "transfer.receiptHolder", value: saved.holder },
          { label: "transfer.receiptAmount", value: formatMoney(saved.amount), money: true },
          { label: "transfer.receiptNote", value: saved.note || t("common.none") },
          { label: "transfer.receiptCashier", value: t("kas.cashierValue") },
          { label: "transfer.receiptRef", value: saved.ref }
        ],
        "transfer.receiptFooter"
      );
    }

    function showSuccess(saved, keepForm) {
      lastSaved = saved;
      successBody.textContent = t("transfer.successBody", { ref: saved.ref });
      var successRef = $("#transfer-success-ref");
      if (successRef) {
        successRef.textContent = saved.ref;
      }
      receiptSlot.replaceChildren(buildTransferReceipt(saved));
      showPanel("success");
      if (!keepForm) {
        source = null;
        dest = null;
        sourceInput.value = "";
        destInput.value = "";
        amountInput.value = "";
        narration.value = "";
        sourceIdentity.hidden = true;
        destIdentity.hidden = true;
        sourceLoaded.hidden = true;
        destVerified.hidden = true;
        setStatus("source", "transfer.sourceStatusEmpty");
        setStatus("dest", "transfer.destEmpty");
        clearFormErrors();
        renderAmountPreview();
        reference = nextReference();
        renderReference();
      }
      if (stateSelect) {
        stateSelect.value = "success";
      }
      stateMode = "success";
    }

    function setFormDisabled(disabled) {
      [sourceInput, destInput, amountInput, narration, sourceLoad, destLoad, reviewOpen].forEach(function (node) {
        if (node) {
          node.disabled = disabled;
        }
      });
      if (disabled) {
        reviewSubmit.disabled = true;
      }
    }

    function resetLookups(clearValues) {
      source = null;
      dest = null;
      if (clearValues) {
        sourceInput.value = "";
        destInput.value = "";
        amountInput.value = "";
        narration.value = "";
      }
      sourceIdentity.hidden = true;
      destIdentity.hidden = true;
      sourceLoaded.hidden = true;
      destVerified.hidden = true;
      setStatus("source", "transfer.sourceStatusEmpty");
      setStatus("dest", "transfer.destEmpty");
      renderAmountPreview();
    }

    function applyState(next) {
      stateMode = next;
      if (stateSelect) {
        stateSelect.value = next;
      }
      busy = false;
      setFormDisabled(false);
      reviewSubmit.disabled = false;
      reviewSubmit.removeAttribute("aria-busy");
      submitSpinner.hidden = true;
      hideSummary();
      clearFormErrors();
      lockedBanner.hidden = true;
      denied.hidden = true;
      work.hidden = false;
      blockedKey = null;
      errorInfo = null;

      if (next === "denied") {
        work.hidden = true;
        denied.hidden = false;
        return;
      }

      if (next === "locked") {
        lockedBanner.hidden = false;
        setFormDisabled(true);
        showPanel("empty");
        return;
      }

      if (next === "normal") {
        resetLookups(true);
        showPanel("empty");
        return;
      }

      if (next === "empty") {
        resetLookups(true);
        showPanel("empty");
        return;
      }

      if (next === "loading") {
        resetLookups(false);
        setStatus("source", "transfer.statusLoading");
        setStatus("dest", "transfer.statusLoading");
        setFormDisabled(true);
        showPanel("empty");
        return;
      }

      if (next === "error") {
        resetLookups(false);
        setStatus("dest", "transfer.statusNotFound");
        setFieldError(destInput, destError, "transfer.error.notFound");
        showPanel("empty");
        return;
      }

      if (next === "insufficient" || next === "duplicate" || next === "unknown") {
        ensureAccounts();
        var cents = parseMoney(amountInput.value);
        if (cents === null || cents <= 0n) {
          amountInput.value = "1";
          renderAmountPreview();
        }
        var amount = parseMoney(amountInput.value) || 0n;
        if (next === "insufficient") {
          showError("transfer.error.title", "transfer.error.insufficient", null, false, false);
        } else if (next === "duplicate") {
          showError("transfer.error.title", "transfer.error.duplicate", { ref: reference }, false, false);
        } else {
          showError("transfer.error.title", "transfer.error.unknown", { ref: reference }, true, false);
        }
        fillReview(amount);
        return;
      }

      if (next === "partial") {
        ensureAccounts();
        if (dest) {
          dest.holderMissing = true;
        }
        renderIdentity("source");
        renderIdentity("dest");
        setStatus("source", "transfer.statusFound");
        setStatus("dest", "transfer.partialBody");
        showBlocked("transfer.reviewHolderMissing", false);
        return;
      }

      if (next === "success") {
        ensureAccounts();
        var successCents = parseMoney(amountInput.value);
        if (successCents === null || successCents <= 0n) {
          amountInput.value = "1";
          renderAmountPreview();
          successCents = 100n;
        }
        showSuccess(
          {
            ref: reference,
            amount: successCents,
            fromNo: source.no,
            toNo: dest.no,
            holder: t("ph.member"),
            note: narration.value.trim(),
            time: formatTime(new Date())
          },
          true
        );
      }
    }

    function ensureAccounts() {
      if (!source) {
        if (!sourceInput.value.trim()) {
          sourceInput.value = DEMO_SOURCE;
        }
        source = accountFor(sourceInput.value.trim() || DEMO_SOURCE);
        renderIdentity("source");
        setStatus("source", "transfer.statusFound");
      }
      if (!dest) {
        if (!destInput.value.trim()) {
          destInput.value = DEMO_DEST;
        }
        dest = accountFor(destInput.value.trim() || DEMO_DEST);
        renderIdentity("dest");
        setStatus("dest", "transfer.statusFound");
      }
    }

    function lookup(kind) {
      if (stateMode === "locked" || stateMode === "denied" || busy) {
        return;
      }
      var input = kind === "source" ? sourceInput : destInput;
      var errorNode = kind === "source" ? sourceError : destError;
      var button = kind === "source" ? sourceLoad : destLoad;
      var value = input.value.trim();
      clearFieldError(input, errorNode);
      hideSummary();

      if (!value) {
        setFieldError(input, errorNode, "transfer.error.accountRequired", true);
        return;
      }
      if (!/^\d{10}$/.test(value)) {
        setFieldError(input, errorNode, "transfer.error.accountFormat", true);
        return;
      }

      button.disabled = true;
      setStatus(kind, "transfer.statusLoading");
      var token = lookupToken + 1;
      lookupToken = token;

      window.setTimeout(function () {
        if (token !== lookupToken) {
          return;
        }
        button.disabled = false;
        if (stateMode === "loading") {
          return;
        }
        if (stateMode === "error") {
          setStatus(kind, "transfer.statusNotFound");
          setFieldError(
            input,
            errorNode,
            kind === "source" ? "transfer.error.sourceNotFound" : "transfer.error.notFound"
          );
          return;
        }
        var account = accountFor(value);
        if (kind === "dest" && stateMode === "partial") {
          account.holderMissing = true;
        }
        if (kind === "source") {
          source = account;
        } else {
          dest = account;
        }
        renderIdentity(kind);
        setStatus(kind, "transfer.statusFound");
      }, 500);
    }

    function validateReview() {
      clearFormErrors();
      var invalid = null;
      var cents = parseMoney(amountInput.value);

      if (!source) {
        setFieldError(sourceInput, sourceError, "transfer.error.sourceLookup");
        invalid = invalid || sourceInput;
      }
      if (!dest) {
        setFieldError(destInput, destError, "transfer.error.destLookup");
        invalid = invalid || destInput;
      }
      if (cents === null) {
        setFieldError(amountInput, amountError, "transfer.error.amountFormat");
        invalid = invalid || amountInput;
      } else if (cents <= 0n) {
        setFieldError(amountInput, amountError, "transfer.error.amountZero");
        invalid = invalid || amountInput;
      }
      if (invalid) {
        showSummary();
        announce(t("common.formSummary"));
        invalid.focus();
        return false;
      }
      if (source.no === dest.no) {
        showBlocked("transfer.reviewSameAccount");
        return false;
      }
      if (dest.holderMissing) {
        showBlocked("transfer.reviewHolderMissing");
        return false;
      }
      fillReview(cents);
      showPanel("filled");
      reviewTitle.focus();
      return true;
    }

    function submitTransfer() {
      if (busy || panel !== "filled") {
        return;
      }
      var cents = parseMoney(amountInput.value);
      if (cents === null || cents <= 0n || !source || !dest) {
        validateReview();
        return;
      }
      busy = true;
      reviewSubmit.disabled = true;
      reviewSubmit.setAttribute("aria-busy", "true");
      submitSpinner.hidden = false;
      reviewFilled.setAttribute("aria-busy", "true");

      window.setTimeout(function () {
        busy = false;
        reviewSubmit.disabled = false;
        reviewSubmit.removeAttribute("aria-busy");
        submitSpinner.hidden = true;
        reviewFilled.removeAttribute("aria-busy");

        if (stateMode === "insufficient" || stateMode === "duplicate" || stateMode === "unknown") {
          if (stateMode === "insufficient") {
            showError("transfer.error.title", "transfer.error.insufficient", null, false);
          } else if (stateMode === "duplicate") {
            showError("transfer.error.title", "transfer.error.duplicate", { ref: reference }, false);
          } else {
            showError("transfer.error.title", "transfer.error.unknown", { ref: reference }, true);
          }
          announce(t(errorInfo.body, errorInfo.vars));
          return;
        }

        var saved = {
          ref: reference,
          amount: cents,
          fromNo: source.no,
          toNo: dest.no,
          holder: t("ph.member"),
          note: narration.value.trim(),
          time: formatTime(new Date())
        };
        showSuccess(saved, false);
        announce(t("transfer.successBody", { ref: saved.ref }));
      }, 800);
    }

    function closeReview() {
      showPanel(panel === "success" ? "success" : "empty");
      if (stateMode !== "success") {
        showPanel("empty");
      }
      amountInput.focus();
    }

    function resetForm() {
      applyState("normal");
      sourceInput.focus();
    }

    sourceForm.addEventListener("submit", function (event) {
      event.preventDefault();
      lookup("source");
    });
    destForm.addEventListener("submit", function (event) {
      event.preventDefault();
      lookup("dest");
    });
    detailsForm.addEventListener("submit", function (event) {
      event.preventDefault();
      validateReview();
    });

    sourceLoad.addEventListener("click", function () {
      lookup("source");
    });
    destLoad.addEventListener("click", function () {
      lookup("dest");
    });

    [sourceInput, destInput].forEach(function (input) {
      input.addEventListener("keydown", function (event) {
        if (event.key === "Enter") {
          event.preventDefault();
          lookup(input === sourceInput ? "source" : "dest");
        }
      });
    });

    sourceInput.addEventListener("input", function () {
      clearFieldError(sourceInput, sourceError);
      source = null;
      sourceIdentity.hidden = true;
      sourceLoaded.hidden = true;
      setStatus("source", "transfer.sourceStatusEmpty");
    });
    destInput.addEventListener("input", function () {
      clearFieldError(destInput, destError);
      dest = null;
      destIdentity.hidden = true;
      destVerified.hidden = true;
      setStatus("dest", "transfer.destEmpty");
    });

    amountInput.addEventListener("input", function () {
      var cleaned = sanitizeAmount(amountInput.value);
      if (cleaned !== amountInput.value) {
        amountInput.value = cleaned;
      }
      clearFieldError(amountInput, amountError);
      renderAmountPreview();
    });

    $("#transfer-review-back").addEventListener("click", closeReview);
    $("#transfer-blocked-back").addEventListener("click", closeReview);
    $("#transfer-error-back").addEventListener("click", function () {
      showPanel("empty");
      amountInput.focus();
    });
    $("#transfer-next").addEventListener("click", resetForm);
    $("#transfer-review-submit").addEventListener("click", submitTransfer);

    checkStatus.addEventListener("click", function () {
      checkStatus.disabled = true;
      checkStatus.textContent = t("transfer.checking");
      window.setTimeout(function () {
        checkStatus.disabled = false;
        checkStatus.textContent = t("transfer.checkStatus");
        stateMode = "normal";
        if (stateSelect) {
          stateSelect.value = "normal";
        }
        hideSummary();
        clearFormErrors();
        if (source && dest) {
          var cents = parseMoney(amountInput.value);
          if (cents !== null && cents > 0n && !dest.holderMissing && source.no !== dest.no) {
            fillReview(cents);
            showPanel("filled");
          } else {
            showPanel("empty");
          }
        } else {
          showPanel("empty");
        }
        announce(t("transfer.checkDone"));
      }, 700);
    });

    $("#transfer-print").addEventListener("click", function () {
      var receipt = receiptSlot.querySelector(".receipt");
      printNode(receipt);
    });

    $all("[data-tx-mode]").forEach(function (button) {
      button.addEventListener("click", function () {
        var mode = button.getAttribute("data-tx-mode");
        if (mode === "deposit" || mode === "withdrawal") {
          window.location.href = "kas.html";
        } else {
          sourceInput.focus();
        }
      });
    });

    if (stateSelect) {
      stateSelect.addEventListener("change", function () {
        applyState(stateSelect.value);
      });
    }

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || busy || document.querySelector("dialog[open]")) {
        return;
      }
      if (panel === "filled" || panel === "blocked" || panel === "error") {
        if (panel === "error") {
          showPanel("empty");
          amountInput.focus();
        } else {
          closeReview();
        }
      }
    });

    function render() {
      renderIdentity("source");
      renderIdentity("dest");
      renderStatuses();
      renderAmountPreview();
      renderReference();
      if (panel === "filled") {
        var cents = parseMoney(amountInput.value);
        if (source && dest && cents !== null) {
          fillReview(cents);
        }
      } else if (panel === "blocked" && blockedKey) {
        blockedReason.textContent = t(blockedKey);
      } else if (panel === "error" && errorInfo) {
        errorTitle.textContent = t(errorInfo.title);
        errorBody.textContent = t(errorInfo.body, errorInfo.vars);
        errorRef.textContent = reference;
        checkStatus.textContent = t("transfer.checkStatus");
      } else if (panel === "success" && lastSaved) {
        successBody.textContent = t("transfer.successBody", { ref: lastSaved.ref });
        var successRef = $("#transfer-success-ref");
        if (successRef) {
          successRef.textContent = lastSaved.ref;
        }
        receiptSlot.replaceChildren(buildTransferReceipt(lastSaved));
      }
    }

    renderers.push(render);
    render();
  }

  /* ------------------------------------------------------------------ */
  /* Close console                                                      */
  /* ------------------------------------------------------------------ */

  function initClose() {
    var consoleRoot = $("#close-console");
    if (!consoleRoot) {
      return;
    }

    var denied = $("#close-denied");
    var daily = $("#close-daily");
    var monthly = $("#close-monthly");
    var yearly = $("#close-yearly");
    var checklistPanel = $("#close-checklist-panel");
    var historyPanel = $("#close-history-panel");
    var checklist = $("#close-checklist");
    var blockCount = $("#close-block-count");
    var blockSummary = $("#close-block-summary");
    var loading = $("#close-loading");
    var dailyBody = $("#close-daily-body");
    var unknownBanner = $("#close-unknown");
    var errorBanner = $("#close-error-banner");
    var partialBanner = $("#close-partial-banner");
    var successBanner = $("#close-success-banner");
    var countInput = $("#close-count");
    var countError = $("#close-count-error");
    var noteInput = $("#close-note");
    var noteError = $("#close-note-error");
    var variance = $("#close-variance");
    var varianceSentence = $("#close-variance-sentence");
    var varianceRegion = $("#close-variance-region");
    var runButton = $("#close-run");
    var runLabel = $("#close-run-label");
    var runSpinner = $("#close-run-spinner");
    var runMessage = $("#close-run-message");
    var runBadge = $("#close-run-badge");
    var certificate = $("#close-certificate");
    var historyBody = $("#close-history-body");
    var historyEmpty = $("#close-history-empty");
    var stateSelect = $("#close-state");
    var dialog = $("#close-dialog");
    var dialogConfirm = $("#close-dialog-confirm");
    var dialogCancel = $("#close-dialog-cancel");

    var level = "daily";
    var stateMode = "blocked";
    var running = false;
    var closed = false;
    var lastTrigger = null;
    var lastRun = null;
    var historyRows = [];

    var expectedCents = 0n;

    var blockedRows = [
      { key: "close.block.cash", count: 1, fix: "close.block.cashFix", href: "kas.html" },
      { key: "close.block.journals", count: 0, fix: "close.block.journalsFix" },
      { key: "close.block.trial", count: 0, fix: "close.block.trialFix" },
      { key: "close.block.approvals", count: 2, fix: "close.block.approvalsFix" },
      { key: "close.block.tasks", count: 0, fix: "close.block.tasksFix" }
    ];

    var readyRows = blockedRows.map(function (row) {
      return { key: row.key, count: 0, fix: row.fix, href: row.href };
    });

    function currentRows() {
      if (
        stateMode === "ready" ||
        stateMode === "empty" ||
        stateMode === "success" ||
        stateMode === "locked" ||
        stateMode === "partial"
      ) {
        return readyRows;
      }
      return blockedRows;
    }

    function blockerCount() {
      if (level !== "daily") {
        return 0;
      }
      return currentRows().reduce(function (total, row) {
        return total + (row.count > 0 ? 1 : 0);
      }, 0);
    }

    function renderChecklist() {
      checklist.replaceChildren();
      var rows = currentRows();
      var count = blockerCount();
      rows.forEach(function (row) {
        var item = el("li");
        var main = el("div", "tx-checklist__main");
        main.appendChild(el("span", "tx-checklist__title", t(row.key)));
        if (row.count > 0) {
          main.appendChild(el("span", "tx-checklist__fix", t(row.fix)));
        }
        item.appendChild(main);

        if (row.count > 0 && row.href) {
          var action = el("a", "tx-checklist__action", t(row.fix));
          action.href = row.href;
          item.appendChild(action);
        }

        var badge = el(
          "span",
          "badge " + (row.count > 0 ? "badge--danger" : "badge--success"),
          row.count > 0 ? t("close.countValue", { count: row.count }) : t("close.ok")
        );
        item.appendChild(badge);
        checklist.appendChild(item);
      });

      if (level === "daily" && stateMode !== "loading" && stateMode !== "error") {
        blockCount.textContent = count > 0 ? t("close.blocks", { count: count }) : t("close.ok");
        blockCount.className = "badge " + (count > 0 ? "badge--danger" : "badge--success");
        blockSummary.textContent = count > 0 ? t("close.runBlocked", { count: count }) : t("close.checklistOk");
      }
    }

    function renderVariance() {
      var counted = parseMoney(countInput.value);
      var mismatch = false;
      varianceRegion.className = "tx-variance";
      countInput.removeAttribute("aria-invalid");
      countError.hidden = true;

      if (counted === null) {
        variance.textContent = formatMoney(0n);
        varianceSentence.textContent = t("close.varianceEmpty");
        noteInput.required = false;
        noteInput.removeAttribute("aria-required");
        return;
      }

      var difference = counted - expectedCents;
      variance.textContent = formatMoney(difference);
      noteInput.required = difference !== 0n;
      if (difference === 0n) {
        varianceRegion.className = "tx-variance tx-variance--match";
        varianceSentence.textContent = t("close.varianceMatch");
        noteInput.removeAttribute("aria-required");
        return;
      }

      mismatch = true;
      varianceRegion.className = "tx-variance tx-variance--mismatch";
      noteInput.setAttribute("aria-required", "true");
      var magnitude = formatMoney(difference < 0n ? -difference : difference);
      var word = difference > 0n ? t("close.varianceMore", { amount: magnitude }) : t("close.varianceLess", { amount: magnitude });
      varianceSentence.textContent = word + " " + t("close.varianceMismatch", { amount: magnitude });
      if (mismatch) {
        varianceSentence.textContent = varianceSentence.textContent.trim();
      }
    }

    function renderHistory() {
      historyBody.replaceChildren();
      historyEmpty.hidden = historyRows.length > 0;
      historyRows.forEach(function (row) {
        var tr = el("tr");
        var date = el("th", "", formatBusinessDate());
        date.scope = "row";
        tr.appendChild(date);
        tr.appendChild(el("td", "", t(row.levelKey)));
        tr.appendChild(el("td", "", t("close.historyDone")));
        tr.appendChild(el("td", "", row.start));
        tr.appendChild(el("td", "", row.end));
        tr.appendChild(el("td", "", t("kas.cashierValue")));
        historyBody.appendChild(tr);
      });
    }

    function renderCertificate() {
      if (!lastRun || level !== "daily") {
        certificate.hidden = true;
        return;
      }
      certificate.hidden = false;
      setText($("#close-cert-level"), lastRun.levelKey);
      $("#close-cert-expected").textContent = formatMoney(lastRun.expected);
      $("#close-cert-counted").textContent = formatMoney(lastRun.counted);
      $("#close-cert-variance").textContent = formatMoney(lastRun.variance);
      $("#close-cert-time").textContent = lastRun.end;
      $("#close-cert-note").textContent = lastRun.note || t("common.none");
    }

    function renderRunState() {
      var count = blockerCount();
      var canRun =
        level === "daily" &&
        !running &&
        !closed &&
        stateMode !== "loading" &&
        stateMode !== "error" &&
        stateMode !== "partial" &&
        stateMode !== "unknown" &&
        stateMode !== "locked" &&
        stateMode !== "denied" &&
        count === 0;

      runButton.hidden = level !== "daily";
      runButton.disabled = !canRun;
      runSpinner.hidden = !running;
      runButton.setAttribute("aria-busy", String(running));
      runLabel.textContent = running ? t("close.runBusy") : t("close.run");

      if (level === "monthly") {
        runMessage.textContent = t("close.monthBody");
        runBadge.textContent = t("tx.valueUnavailable");
        runBadge.className = "badge badge--warning";
        return;
      }
      if (level === "yearly") {
        runMessage.textContent = t("close.yearMissing");
        runBadge.textContent = t("tx.valueUnavailable");
        runBadge.className = "badge badge--warning";
        return;
      }
      if (stateMode === "loading") {
        runMessage.textContent = t("close.loading");
        runBadge.textContent = t("tx.preview.loading");
        runBadge.className = "badge";
        return;
      }
      if (stateMode === "unknown") {
        runMessage.textContent = t("close.unknownBody");
        runBadge.textContent = t("tx.preview.unknown");
        runBadge.className = "badge badge--warning";
        return;
      }
      if (stateMode === "locked" || closed) {
        runMessage.textContent = t("close.lockedBody");
        runBadge.textContent = t("close.ok");
        runBadge.className = "badge badge--success";
        return;
      }
      if (stateMode === "partial") {
        runMessage.textContent = t("close.partialBody");
        runBadge.textContent = t("tx.preview.partial");
        runBadge.className = "badge badge--warning";
        return;
      }
      if (stateMode === "error") {
        runMessage.textContent = t("close.errorBody");
        runBadge.textContent = t("tx.preview.error");
        runBadge.className = "badge badge--danger";
        return;
      }
      if (count > 0) {
        runMessage.textContent = t("close.runBlocked", { count: count });
        runBadge.textContent = t("close.blocks", { count: count });
        runBadge.className = "badge badge--danger";
        return;
      }
      runMessage.textContent = t("close.runReady");
      runBadge.textContent = t("close.ok");
      runBadge.className = "badge badge--success";
    }

    function setLevel(next) {
      level = next;
      $all("[data-close-level]").forEach(function (button) {
        button.setAttribute("aria-pressed", String(button.getAttribute("data-close-level") === next));
      });
      daily.hidden = next !== "daily";
      monthly.hidden = next !== "monthly";
      yearly.hidden = next !== "yearly";
      checklistPanel.hidden = next !== "daily";
      certificate.hidden = next !== "daily" || !lastRun;
      renderChecklist();
      renderRunState();
    }

    function makeDefaultRun() {
      return {
        levelKey: "close.levelDaily",
        expected: expectedCents,
        counted: 0n,
        variance: 0n,
        note: "",
        start: formatTime(new Date()),
        end: formatTime(new Date())
      };
    }

    function applyState(next) {
      stateMode = next;
      if (stateSelect) {
        stateSelect.value = next;
      }
      denied.hidden = true;
      consoleRoot.hidden = false;
      unknownBanner.hidden = true;
      errorBanner.hidden = true;
      partialBanner.hidden = true;
      successBanner.hidden = true;
      loading.hidden = true;
      dailyBody.hidden = false;
      checklistPanel.hidden = level !== "daily";
      historyPanel.hidden = false;
      certificate.hidden = true;
      runButton.hidden = false;
      running = false;
      closed = false;
      lastRun = null;
      countInput.disabled = false;
      noteInput.disabled = false;
      noteInput.required = false;
      noteInput.removeAttribute("aria-required");

      if (next === "denied") {
        consoleRoot.hidden = true;
        denied.hidden = false;
        return;
      }

      if (next === "loading") {
        loading.hidden = false;
        dailyBody.hidden = true;
        checklistPanel.hidden = true;
        historyPanel.hidden = true;
        renderRunState();
        return;
      }

      if (next === "error") {
        errorBanner.hidden = false;
        checklistPanel.hidden = true;
        historyPanel.hidden = true;
        renderRunState();
        return;
      }

      if (next === "partial") {
        partialBanner.hidden = false;
        historyPanel.hidden = true;
        renderChecklist();
        renderRunState();
        return;
      }

      if (next === "unknown") {
        unknownBanner.hidden = false;
        renderRunState();
        return;
      }

      if (next === "locked") {
        closed = true;
        countInput.disabled = true;
        noteInput.disabled = true;
        lastRun = makeDefaultRun();
        certificate.hidden = false;
        renderCertificate();
      }

      if (next === "success") {
        closed = true;
        if (!lastRun) {
          var countedPreview = parseMoney(countInput.value) || 0n;
          lastRun = makeDefaultRun();
          lastRun.counted = countedPreview;
          lastRun.variance = countedPreview - expectedCents;
          lastRun.note = noteInput.value.trim();
        }
        successBanner.hidden = false;
        renderCertificate();
        historyRows = historyRows.length
          ? historyRows
          : [
              {
                date: formatBusinessDate(),
                levelKey: "close.levelDaily",
                start: lastRun.start,
                end: lastRun.end
              }
            ];
      }

      if (next === "empty") {
        historyRows = [];
      }

      if (next === "ready" || next === "blocked" || next === "empty") {
        historyRows = next === "empty" ? [] : historyRows;
      }

      renderChecklist();
      renderHistory();
      renderVariance();
      renderRunState();
    }

    countInput.addEventListener("input", function () {
      var cleaned = sanitizeAmount(countInput.value);
      if (cleaned !== countInput.value) {
        countInput.value = cleaned;
      }
      countError.hidden = true;
      countInput.removeAttribute("aria-invalid");
      noteError.hidden = true;
      renderVariance();
    });

    noteInput.addEventListener("input", function () {
      noteError.hidden = true;
      noteInput.removeAttribute("aria-invalid");
    });

    $all("[data-close-level]").forEach(function (button) {
      button.addEventListener("click", function () {
        setLevel(button.getAttribute("data-close-level"));
      });
    });

    runButton.addEventListener("click", function () {
      if (runButton.disabled) {
        return;
      }
      var counted = parseMoney(countInput.value);
      var difference = counted === null ? 0n : counted - expectedCents;
      if (difference !== 0n && !noteInput.value.trim()) {
        setFieldError(noteInput, noteError, "close.noteRequired", true);
        return;
      }
      lastTrigger = runButton;
      dialog.showModal();
      if (dialogCancel) {
        dialogCancel.focus();
      }
    });

    dialog.addEventListener("close", function () {
      if (lastTrigger && document.contains(lastTrigger)) {
        lastTrigger.focus();
      }
    });

    dialogConfirm.addEventListener("click", function () {
      if (running) {
        return;
      }
      running = true;
      dialog.setAttribute("data-busy", "true");
      dialogConfirm.disabled = true;
      dialogCancel.disabled = true;
      renderRunState();
      var started = formatTime(new Date());
      window.setTimeout(function () {
        running = false;
        dialog.removeAttribute("data-busy");
        dialogConfirm.disabled = false;
        dialogCancel.disabled = false;
        var counted = parseMoney(countInput.value) || 0n;
        lastRun = {
          levelKey: "close.levelDaily",
          expected: expectedCents,
          counted: counted,
          variance: counted - expectedCents,
          note: noteInput.value.trim(),
          start: started,
          end: formatTime(new Date())
        };
        closed = true;
        stateMode = "success";
        if (stateSelect) {
          stateSelect.value = "success";
        }
        successBanner.hidden = false;
        renderCertificate();
        historyRows = [
          {
            date: formatBusinessDate(),
            levelKey: "close.levelDaily",
            start: lastRun.start,
            end: lastRun.end
          }
        ];
        renderHistory();
        renderRunState();
        dialog.close();
        announce(t("close.successTitle"));
      }, 900);
    });

    $("#close-reload").addEventListener("click", function () {
      applyState("blocked");
      announce(t("close.reload"));
    });
    $("#close-retry").addEventListener("click", function () {
      applyState("blocked");
    });
    $("#close-partial-retry").addEventListener("click", function () {
      applyState("blocked");
    });

    $("#close-print").addEventListener("click", function () {
      var node = certificate.cloneNode(true);
      printNode(node);
    });

    if (stateSelect) {
      stateSelect.addEventListener("change", function () {
        applyState(stateSelect.value);
      });
    }

    function render() {
      renderChecklist();
      renderVariance();
      renderHistory();
      if (lastRun) {
        renderCertificate();
      }
      renderRunState();
      if (stateSelect) {
        stateSelect.value = stateMode;
      }
    }

    renderers.push(render);
    setLevel("daily");
    applyState("blocked");
    render();
  }

  /* ------------------------------------------------------------------ */
  /* Loan detail                                                        */
  /* ------------------------------------------------------------------ */

  function initLoan() {
    var content = $("#loan-content");
    if (!content) {
      return;
    }

    var denied = $("#loan-denied");
    var lockedBanner = $("#loan-locked-banner");
    var partialBanner = $("#loan-partial-banner");
    var loading = $("#loan-loading");
    var errorState = $("#loan-error-state");
    var summaryFacts = $("#loan-summary-facts");
    var schedulePanel = $("#loan-schedule-panel");
    var scheduleTable = $("#loan-schedule-table-wrap");
    var scheduleEmpty = $("#loan-schedule-empty");
    var historyPanel = $("#loan-history-panel");
    var asideInfo = $("#loan-aside-info");
    var payForm = $("#loan-pay-form");
    var amountInput = $("#loan-amount");
    var amountPreview = $("#loan-preview");
    var amountError = $("#loan-pay-error");
    var sourceSelect = $("#loan-source");
    var sourceError = $("#loan-source-error");
    var paySummary = $("#loan-pay-summary");
    var reviewFilled = $("#loan-review-filled");
    var reviewKey = $("#loan-review-key");
    var successPanel = $("#loan-success");
    var successBody = $("#loan-success-body");
    var successKey = $("#loan-success-key");
    var receiptSlot = $("#loan-receipt-slot");
    var errorPanel = $("#loan-review-error");
    var errorTitle = $("#loan-error-title");
    var errorBody = $("#loan-error-body");
    var errorRef = $("#loan-error-ref");
    var checkStatus = $("#loan-check-status");
    var stateSelect = $("#loan-state");
    var reviewTitle = $("#loan-review-title");

    var query = new URLSearchParams(window.location.search);
    var tab = query.get("tab");
    if (tab !== "jadwal" && tab !== "pay" && tab !== "riwayat") {
      tab = "jadwal";
    }

    var stateMode = "normal";
    var panel = "empty";
    var busy = false;
    var keySequence = 1;
    var refSequence = 140;
    var reference = "TRX-000140";
    var lastSaved = null;
    var errorInfo = null;

    function currentKey() {
      return "PAY-" + String(keySequence).padStart(4, "0");
    }

    function nextReference() {
      refSequence += 1;
      return "TRX-" + String(refSequence).padStart(6, "0");
    }

    function setTab(next, updateUrl) {
      tab = next;
      $all("[data-loan-tab]").forEach(function (link) {
        var active = link.getAttribute("data-loan-tab") === next;
        if (active) {
          link.setAttribute("aria-current", "page");
        } else {
          link.removeAttribute("aria-current");
        }
      });
      schedulePanel.hidden = next === "riwayat";
      historyPanel.hidden = next !== "riwayat";
      asideInfo.hidden = next === "pay";
      payForm.hidden = next !== "pay";
      if (next !== "pay") {
        reviewFilled.hidden = true;
        successPanel.hidden = true;
      }
      if (updateUrl && window.history && window.history.replaceState) {
        var url = new URL(window.location.href);
        url.searchParams.set("tab", next);
        window.history.replaceState(null, "", url.toString());
      }
    }

    function showPanel(name) {
      panel = name;
      reviewFilled.hidden = name !== "filled";
      errorPanel.hidden = name !== "error";
      successPanel.hidden = name !== "success";
      if (name === "filled") {
        reviewTitle.focus();
      }
    }

    function renderAmountPreview() {
      var cents = parseMoney(amountInput.value);
      amountPreview.textContent = cents !== null && cents > 0n ? formatMoney(cents) : "";
    }

    function clearErrors() {
      clearFieldError(sourceSelect, sourceError);
      clearFieldError(amountInput, amountError);
      if (paySummary) {
        paySummary.hidden = true;
        paySummary.textContent = "";
      }
    }

    function showSummary() {
      if (paySummary) {
        paySummary.textContent = t("common.formSummary");
        paySummary.hidden = false;
      }
    }

    function buildLoanReceipt(saved) {
      return buildReceipt(
        "loan.payReceiptTitle",
        [
          { label: "loan.payReceiptDate", value: formatBusinessDate() },
          { label: "loan.payReceiptTime", value: saved.time },
          { label: "loan.payReceiptMember", value: t("ph.member") },
          { label: "loan.payReceiptLoanNo", value: t("ph.loanNo") },
          { label: "loan.payReceiptSource", value: t("loan.paySourceOption") },
          { label: "loan.payReceiptAmount", value: formatMoney(saved.amount), money: true },
          { label: "loan.payReceiptSplit", value: t("loan.payReceiptSplitValue") },
          { label: "loan.payReceiptRef", value: saved.ref }
        ],
        "loan.payReceiptFooter"
      );
    }

    function showSuccess(saved, keepForm) {
      lastSaved = saved;
      successBody.textContent = t("loan.paySuccessBody", { ref: saved.ref });
      successKey.textContent = currentKey();
      $("#loan-success-ref").textContent = saved.ref;
      receiptSlot.replaceChildren(buildLoanReceipt(saved));
      showPanel("success");
      if (!keepForm) {
        amountInput.value = "";
        sourceSelect.selectedIndex = 0;
        renderAmountPreview();
        clearErrors();
        reviewFilled.hidden = true;
        keySequence += 1;
        reference = nextReference();
        successKey.textContent = currentKey();
        reviewKey.textContent = currentKey();
      }
      if (stateSelect) {
        stateSelect.value = "success";
      }
      stateMode = "success";
    }

    function showError(titleKey, bodyKey, canCheck) {
      errorInfo = { title: titleKey, body: bodyKey, check: Boolean(canCheck) };
      errorTitle.textContent = t(titleKey);
      errorBody.textContent = t(bodyKey, { ref: reference });
      errorRef.textContent = reference;
      checkStatus.hidden = !canCheck;
      showPanel("error");
    }

    function setPaymentDisabled(disabled, reasonKey) {
      [sourceSelect, amountInput, $("#loan-review-open")].forEach(function (node) {
        if (node) {
          node.disabled = disabled;
        }
      });
      if (disabled && reasonKey) {
        amountError.textContent = t(reasonKey);
        amountError.hidden = false;
        amountInput.setAttribute("aria-invalid", "true");
      }
    }

    function fillReview(cents) {
      $("#loan-review-source").textContent = t("loan.paySourceOption");
      $("#loan-review-amount").textContent = formatMoney(cents);
      reviewKey.textContent = currentKey();
    }

    function validateReview() {
      clearErrors();
      if (stateMode === "empty" || stateMode === "partial" || stateMode === "locked" || stateMode === "loading" || stateMode === "unknown") {
        var blockedKey =
          stateMode === "empty" || stateMode === "partial"
            ? "loan.payError.scheduleMissing"
            : stateMode === "locked"
              ? "loan.payError.locked"
              : stateMode === "unknown"
                ? "loan.payError.unknownShort"
                : "loan.payError.notReady";
        setFieldError(amountInput, amountError, blockedKey, true);
        return;
      }
      var cents = parseMoney(amountInput.value);
      var invalid = null;
      if (!sourceSelect.value) {
        setFieldError(sourceSelect, sourceError, "loan.payError.source");
        invalid = invalid || sourceSelect;
      }
      if (cents === null) {
        setFieldError(amountInput, amountError, "loan.payError.amountFormat");
        invalid = invalid || amountInput;
      } else if (cents <= 0n) {
        setFieldError(amountInput, amountError, "loan.payError.amountZero");
        invalid = invalid || amountInput;
      }
      if (invalid) {
        showSummary();
        announce(t("common.formSummary"));
        invalid.focus();
        return;
      }
      fillReview(cents);
      showPanel("filled");
    }

    function submitPayment() {
      if (busy || panel !== "filled") {
        return;
      }
      var cents = parseMoney(amountInput.value);
      if (cents === null || cents <= 0n) {
        validateReview();
        return;
      }
      busy = true;
      var submit = $("#loan-review-submit");
      submit.disabled = true;
      submit.setAttribute("aria-busy", "true");
      $("#loan-submit-spinner").hidden = false;
      reviewFilled.setAttribute("aria-busy", "true");

      window.setTimeout(function () {
        busy = false;
        submit.disabled = false;
        submit.removeAttribute("aria-busy");
        $("#loan-submit-spinner").hidden = true;
        reviewFilled.removeAttribute("aria-busy");

        if (stateMode === "unknown") {
          showError("loan.unknownTitle", "loan.unknownBody", true);
          announce(t("loan.unknownBody", { ref: reference }));
          return;
        }

        var saved = {
          ref: reference,
          amount: cents,
          time: formatTime(new Date())
        };
        showSuccess(saved, false);
        announce(t("loan.paySuccessBody", { ref: saved.ref }));
      }, 800);
    }

    function applyState(next) {
      stateMode = next;
      if (stateSelect) {
        stateSelect.value = next;
      }
      denied.hidden = true;
      content.hidden = false;
      lockedBanner.hidden = true;
      partialBanner.hidden = true;
      loading.hidden = true;
      errorState.hidden = true;
      summaryFacts.hidden = false;
      schedulePanel.hidden = tab === "riwayat";
      scheduleTable.hidden = false;
      scheduleEmpty.hidden = true;
      amountError.hidden = true;
      amountInput.removeAttribute("aria-invalid");
      setPaymentDisabled(false);
      reviewFilled.hidden = true;
      errorPanel.hidden = true;
      successPanel.hidden = true;

      if (next === "denied") {
        content.hidden = true;
        denied.hidden = false;
        return;
      }

      if (next === "loading") {
        loading.hidden = false;
        setPaymentDisabled(true);
        return;
      }

      if (next === "error") {
        errorState.hidden = false;
        summaryFacts.hidden = true;
        schedulePanel.hidden = true;
        setPaymentDisabled(true);
        return;
      }

      if (next === "partial") {
        partialBanner.hidden = false;
        if (tab !== "pay") {
          setTab("pay", false);
        }
        scheduleTable.hidden = true;
        scheduleEmpty.hidden = false;
        setPaymentDisabled(true, "loan.payError.scheduleMissing");
        return;
      }

      if (next === "locked") {
        lockedBanner.hidden = false;
        if (tab !== "pay") {
          setTab("pay", false);
        }
        setPaymentDisabled(true, "loan.payError.locked");
        return;
      }

      if (next === "empty") {
        if (tab !== "pay") {
          setTab("pay", false);
        }
        scheduleTable.hidden = true;
        scheduleEmpty.hidden = false;
        setPaymentDisabled(true, "loan.payError.scheduleMissing");
        return;
      }

      if (next === "success") {
        if (tab !== "pay") {
          setTab("pay", false);
        }
        var cents = parseMoney(amountInput.value);
        if (cents === null || cents <= 0n) {
          amountInput.value = "1";
          renderAmountPreview();
          cents = 100n;
        }
        showSuccess(
          {
            ref: reference,
            amount: cents,
            time: formatTime(new Date())
          },
          true
        );
        return;
      }

      if (next === "unknown") {
        if (tab !== "pay") {
          setTab("pay", false);
        }
        showError("loan.unknownTitle", "loan.unknownBody", true);
        return;
      }
    }

    $("#loan-review-open").addEventListener("click", validateReview);
    $("#loan-review-back").addEventListener("click", function () {
      showPanel("empty");
      amountInput.focus();
    });
    $("#loan-review-submit").addEventListener("click", submitPayment);
    $("#loan-next").addEventListener("click", function () {
      successPanel.hidden = true;
      showPanel("empty");
      stateMode = "normal";
      if (stateSelect) {
        stateSelect.value = "normal";
      }
      amountInput.focus();
    });
    $("#loan-error-back").addEventListener("click", function () {
      showPanel("empty");
      amountInput.focus();
    });
    $("#loan-retry").addEventListener("click", function () {
      applyState("normal");
    });

    checkStatus.addEventListener("click", function () {
      checkStatus.disabled = true;
      window.setTimeout(function () {
        checkStatus.disabled = false;
        stateMode = "normal";
        if (stateSelect) {
          stateSelect.value = "normal";
        }
        errorPanel.hidden = true;
        showPanel("empty");
        announce(t("loan.checkDone"));
      }, 700);
    });

    amountInput.addEventListener("input", function () {
      var cleaned = sanitizeAmount(amountInput.value);
      if (cleaned !== amountInput.value) {
        amountInput.value = cleaned;
      }
      clearFieldError(amountInput, amountError);
      renderAmountPreview();
    });

    sourceSelect.addEventListener("change", function () {
      clearFieldError(sourceSelect, sourceError);
    });

    if (stateSelect) {
      stateSelect.addEventListener("change", function () {
        applyState(stateSelect.value);
      });
    }

    $("#loan-print").addEventListener("click", function () {
      var receipt = receiptSlot.querySelector(".receipt");
      printNode(receipt);
    });

    $all("[data-loan-tab]").forEach(function (link) {
      link.addEventListener("click", function (event) {
        event.preventDefault();
        setTab(link.getAttribute("data-loan-tab"), true);
      });
    });

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || busy || document.querySelector("dialog[open]")) {
        return;
      }
      if (panel === "filled" || panel === "error") {
        showPanel("empty");
        amountInput.focus();
      }
    });

    function render() {
      renderAmountPreview();
      reviewKey.textContent = currentKey();
      if (panel === "filled") {
        var cents = parseMoney(amountInput.value);
        if (cents !== null) {
          fillReview(cents);
        }
      } else if (panel === "error" && errorInfo) {
        errorTitle.textContent = t(errorInfo.title);
        errorBody.textContent = t(errorInfo.body, { ref: reference });
        errorRef.textContent = reference;
        checkStatus.textContent = t("loan.checkStatus");
      } else if (panel === "success" && lastSaved) {
        successBody.textContent = t("loan.paySuccessBody", { ref: lastSaved.ref });
        successKey.textContent = currentKey();
        $("#loan-success-ref").textContent = lastSaved.ref;
        receiptSlot.replaceChildren(buildLoanReceipt(lastSaved));
      }
    }

    renderers.push(render);
    setTab(tab, false);
    render();
    if (tab === "pay") {
      applyState("normal");
    }
  }

  /* ------------------------------------------------------------------ */
  /* Boot                                                               */
  /* ------------------------------------------------------------------ */

  initCopyButtons();
  initLocaleRefresh();

  var page = document.body.getAttribute("data-tx-page");
  if (page === "login") {
    initLogin();
  } else if (page === "transfer") {
    initTransfer();
  } else if (page === "close") {
    initClose();
  } else if (page === "loan") {
    initLoan();
  }
})();
