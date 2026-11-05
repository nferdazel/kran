/* Behaviour for the governance, list and report screens. Plain ES2020. */
(function () {
  "use strict";

  var EXTRA = window.KRAN_EXTRA_I18N || { id: {}, en: {} };

  /* ------------------------------------------------------------------ */
  /* Text, money, dates                                                  */
  /* ------------------------------------------------------------------ */

  function currentLocale() {
    return document.documentElement.lang.indexOf("en") === 0 ? "en" : "id";
  }

  function localeTag() {
    return currentLocale() === "en" ? "en-US" : "id-ID";
  }

  function t(key, vars) {
    var active = EXTRA[currentLocale()] || EXTRA.id || {};
    var text = Object.prototype.hasOwnProperty.call(active, key)
      ? active[key]
      : (EXTRA.id && EXTRA.id[key]);
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

  function formatInt(value) {
    return new Intl.NumberFormat(localeTag(), { maximumFractionDigits: 0 }).format(value);
  }

  function formatMoney(raw) {
    var source = String(raw === undefined || raw === null ? "0" : raw).trim();
    var negative = source.charAt(0) === "-";
    var unsigned = negative ? source.slice(1) : source;
    var parts = unsigned.split(/[.,]/);
    var whole = (parts[0] || "0").replace(/\D/g, "") || "0";
    var fraction = ((parts[1] || "").replace(/\D/g, "") + "00").slice(0, 2);
    var grouped = new Intl.NumberFormat(localeTag(), {
      useGrouping: true,
      maximumFractionDigits: 0
    }).format(BigInt(whole));
    return (negative ? "-" : "") + grouped + (currentLocale() === "en" ? "." : ",") + fraction;
  }

  function toCents(raw) {
    if (raw === null || raw === undefined || raw === "") {
      return null;
    }
    var source = String(raw).trim().replace(",", ".");
    if (!/^-?\d+(\.\d{0,2})?$/.test(source)) {
      return null;
    }
    var negative = source.charAt(0) === "-";
    var unsigned = negative ? source.slice(1) : source;
    var parts = unsigned.split(".");
    var whole = parts[0] || "0";
    var fraction = ((parts[1] || "") + "00").slice(0, 2);
    var cents = BigInt(whole) * 100n + BigInt(fraction);
    return negative ? -cents : cents;
  }

  function pad(value, size) {
    return String(value).padStart(size, "0");
  }

  /* ------------------------------------------------------------------ */
  /* DOM helpers                                                         */
  /* ------------------------------------------------------------------ */

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

  function byId(id) {
    return document.getElementById(id);
  }

  function all(selector, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(selector));
  }

  var ICONS = {
    check: '<path d="m5 12 5 5 9-10"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    alert: '<path d="M12 3 22 20H2Z"/><path d="M12 9v5"/><path d="M12 17h.01"/>',
    minus: '<circle cx="12" cy="12" r="9"/><path d="M8 12h8"/>'
  };

  function icon(name, className) {
    var template = document.createElement("template");
    template.innerHTML =
      '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" class="' +
      (className || "icon icon--sm") +
      '">' +
      (ICONS[name] || ICONS.minus) +
      "</svg>";
    return template.content.firstElementChild;
  }

  function badge(tone, text) {
    var span = el("span", "badge" + (tone && tone !== "neutral" ? " badge--" + tone : ""));
    var symbol = tone === "success" ? "check" : tone === "danger" ? "alert" : tone === "warning" ? "clock" : "minus";
    span.appendChild(icon(symbol));
    span.appendChild(el("span", "", text));
    return span;
  }

  function announce(message) {
    var live = byId("live");
    if (!live) {
      return;
    }
    live.textContent = "";
    window.requestAnimationFrame(function () {
      live.textContent = message;
    });
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
        announce(t(ok ? "gov.copied" : "gov.copyFailed"));
      } catch (error) {
        announce(t("gov.copyFailed"));
      }
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(function () {
        announce(t("gov.copied"));
      }, fallback);
    } else {
      fallback();
    }
  }

  /* ------------------------------------------------------------------ */
  /* Dialog helpers                                                      */
  /* ------------------------------------------------------------------ */

  function openDialog(dialog, trigger) {
    if (!dialog) {
      return;
    }
    if (dialog.open) {
      return;
    }
    dialog.__govTrigger = trigger || (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    dialog.showModal();
    var title = dialog.querySelector(".dialog__title");
    if (title) {
      if (!title.hasAttribute("tabindex")) {
        title.setAttribute("tabindex", "-1");
      }
      title.focus();
    }
  }

  function closeDialog(dialog) {
    if (dialog && dialog.open) {
      dialog.close();
    }
  }

  function restoreTrigger(dialog) {
    if (!dialog.__govTrigger) {
      return;
    }
    var trigger = dialog.__govTrigger;
    dialog.__govTrigger = null;
    if (trigger && document.contains(trigger)) {
      trigger.focus();
    } else {
      var main = byId("main");
      if (main) {
        main.focus();
      }
    }
  }

  /* ------------------------------------------------------------------ */
  /* Reusable blocks                                                     */
  /* ------------------------------------------------------------------ */

  var errorSequence = 0;

  function loadingContent(label) {
    var box = el("div", "loading-state");
    box.setAttribute("role", "status");
    box.setAttribute("aria-busy", "true");
    var bar = el("span", "loading-state__bar");
    bar.setAttribute("aria-hidden", "true");
    box.appendChild(bar);
    box.appendChild(el("span", "", label));
    return box;
  }

  function emptyContent(title, body, actionLabel, onAction) {
    var box = el("div", "empty-state");
    box.appendChild(el("p", "empty-state__title", title));
    box.appendChild(el("p", "empty-state__body", body));
    if (actionLabel && onAction) {
      var actions = el("div", "empty-state__actions");
      var button = el("button", "btn btn--sm", actionLabel);
      button.type = "button";
      button.addEventListener("click", onAction);
      actions.appendChild(button);
      box.appendChild(actions);
    }
    return box;
  }

  function errorContent(title, body, onRetry) {
    var box = el("div", "error-state");
    box.setAttribute("role", "alert");
    box.appendChild(icon("alert", "icon error-state__icon"));
    box.appendChild(el("p", "error-state__title", title));
    box.appendChild(el("p", "error-state__body", body));
    var referenceId = "gov-error-ref-" + (++errorSequence);
    var reference = el("p", "error-state__reference");
    reference.appendChild(document.createTextNode(t("gov.reference") + ": "));
    var code = el("code", "num", "ERR-0007");
    code.id = referenceId;
    reference.appendChild(code);
    box.appendChild(reference);
    var actions = el("div", "error-state__actions");
    var retry = el("button", "btn", t("gov.retry"));
    retry.type = "button";
    retry.addEventListener("click", onRetry);
    actions.appendChild(retry);
    var copy = el("button", "btn btn--ghost", t("gov.copyRef"));
    copy.type = "button";
    copy.addEventListener("click", function () {
      copyText(code.textContent.trim());
    });
    actions.appendChild(copy);
    box.appendChild(actions);
    return box;
  }

  function messageRow(colspan, content) {
    var tr = el("tr");
    var td = el("td");
    td.colSpan = colspan;
    td.appendChild(content);
    tr.appendChild(td);
    return tr;
  }

  function pageButton(label, active, pageNumber, onClick) {
    var button = el("button", "btn btn--sm", label);
    button.type = "button";
    if (active) {
      button.setAttribute("aria-current", "page");
    }
    if (pageNumber !== undefined) {
      button.setAttribute("data-page", String(pageNumber));
    }
    button.addEventListener("click", onClick);
    return button;
  }

  function sortRows(rows, valueOf, direction) {
    var copy = rows.slice();
    copy.sort(function (a, b) {
      var left = valueOf(a);
      var right = valueOf(b);
      var result = typeof left === "number" && typeof right === "number"
        ? left - right
        : String(left).localeCompare(String(right), localeTag());
      return direction === "asc" ? result : -result;
    });
    return copy;
  }

  function setAriaSort(table, key, direction) {
    all("thead th", table).forEach(function (th) {
      if (th.getAttribute("data-column") === key) {
        th.setAttribute("aria-sort", direction === "asc" ? "ascending" : "descending");
      } else {
        th.removeAttribute("aria-sort");
      }
    });
  }

  function wireStates(rootId, onChange) {
    var root = byId(rootId);
    if (!root) {
      return { set: function () {} };
    }
    var buttons = all("[data-gov-state]", root);

    function paint(state) {
      buttons.forEach(function (button) {
        button.setAttribute("aria-pressed", String(button.getAttribute("data-gov-state") === state));
      });
    }

    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        var next = button.getAttribute("data-gov-state");
        paint(next);
        onChange(next);
        announce(t("gov.stateAnnounce", { state: button.textContent.trim() }));
      });
    });

    return {
      set: function (state) {
        paint(state);
      }
    };
  }

  /* ------------------------------------------------------------------ */
  /* Locale hook (app.js updates the lang attribute on switch)           */
  /* ------------------------------------------------------------------ */

  var localeHooks = [];

  function onLocale(fn) {
    localeHooks.push(fn);
  }

  if (window.MutationObserver) {
    var localeObserver = new MutationObserver(function (records) {
      for (var index = 0; index < records.length; index += 1) {
        if (records[index].attributeName === "lang") {
          localeHooks.forEach(function (hook) {
            hook();
          });
          return;
        }
      }
    });
    localeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["lang"] });
  }

  /* ------------------------------------------------------------------ */
  /* K-06 member register                                                */
  /* ------------------------------------------------------------------ */

  function initMembers() {
    var table = byId("members-table");
    if (!table) {
      return;
    }

    var region = byId("members-region");
    var tbody = byId("members-tbody");
    var countLine = byId("members-count");
    var scopeLine = byId("members-scope");
    var pager = byId("members-pager");
    var rangeLine = byId("members-range");
    var pageLine = byId("members-page-label");
    var pagesBox = byId("members-pages");
    var prev = byId("members-prev");
    var next = byId("members-next");
    var pageSizeSelect = byId("members-page-size");
    var search = byId("members-search");
    var statusFilter = byId("members-status");
    var branchFilter = byId("members-branch");
    var clearButton = byId("members-clear");
    var newButton = byId("members-new");
    var readonlyBanner = byId("members-readonly");
    var partialBanner = byId("members-partial");
    var content = byId("members-content");
    var denied = byId("members-denied");
    var newDialog = byId("members-new-dialog");

    var statuses = ["active", "dormant", "arrears", "exited"];
    var records = [];
    for (var index = 1; index <= 120; index += 1) {
      records.push({
        index: index,
        branch: ((index - 1) % 3) + 1,
        status: statuses[(index - 1) % statuses.length]
      });
    }

    var view = {
      state: "normal",
      query: "",
      status: "",
      branch: "",
      page: 1,
      pageSize: 50,
      sortKey: "number",
      direction: "asc"
    };
    var filterTimer = null;
    var filterSequence = 0;

    function memberName(record) {
      return t("gov.ph.member") + " " + pad(record.index, 2);
    }

    function memberNumber(record) {
      return t("gov.ph.memberNo") + " " + pad(record.index, 4);
    }

    function memberBranch(record) {
      return t("gov.branch." + record.branch);
    }

    function memberStatus(record) {
      return t("gov.status." + record.status);
    }

    function statusTone(status) {
      if (status === "active") {
        return "success";
      }
      if (status === "dormant") {
        return "warning";
      }
      if (status === "arrears") {
        return "danger";
      }
      return "neutral";
    }

    function filtered() {
      var query = view.query.trim().toLowerCase();
      return records.filter(function (record) {
        var name = memberName(record).toLowerCase();
        var number = memberNumber(record).toLowerCase();
        var digits = pad(record.index, 4);
        var matchesQuery = query === "" || name.indexOf(query) >= 0 || number.indexOf(query) >= 0 || digits.indexOf(query) >= 0;
        var matchesStatus = view.status === "" || record.status === view.status;
        var matchesBranch = view.branch === "" || String(record.branch) === view.branch;
        return matchesQuery && matchesStatus && matchesBranch;
      });
    }

    function sortValue(record) {
      return view.sortKey === "name" ? memberName(record) : pad(record.index, 4);
    }

    function renderPages(pageCount) {
      pagesBox.replaceChildren();
      for (var page = 1; page <= pageCount; page += 1) {
        (function (pageNumber) {
          pagesBox.appendChild(
            pageButton(formatInt(pageNumber), pageNumber === view.page, pageNumber, function () {
              goToPage(pageNumber);
            })
          );
        })(page);
      }
    }

    function goToPage(pageNumber) {
      view.page = pageNumber;
      renderTable();
      var target = pagesBox.querySelector('[data-page="' + pageNumber + '"]');
      if (target) {
        target.focus();
      }
      announce(t("gov.pageAnnounce", { page: formatInt(pageNumber), range: rangeLine.textContent }));
    }

    function renderRows(rows) {
      tbody.replaceChildren();
      rows.forEach(function (record) {
        var tr = el("tr");
        var number = el("th", "num", memberNumber(record));
        number.scope = "row";
        tr.appendChild(number);
        tr.appendChild(el("td", "", memberName(record)));
        tr.appendChild(el("td", "", memberBranch(record)));
        var status = el("td");
        status.appendChild(badge(statusTone(record.status), memberStatus(record)));
        tr.appendChild(status);
        tr.appendChild(el("td", "", t("gov.ph.date")));
        var savings = el("td", "money-cell");
        savings.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(savings);
        var loans = el("td", "money-cell");
        loans.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(loans);
        var action = el("td");
        var link = el("a", "btn btn--sm", t("members.open"));
        link.href = "anggota-detail.html" + (record.status === "exited" ? "?state=exited" : "");
        action.appendChild(link);
        tr.appendChild(action);
        tbody.appendChild(tr);
      });
    }

    function renderTable() {
      region.removeAttribute("aria-busy");

      if (view.state === "loading") {
        tbody.replaceChildren(messageRow(8, loadingContent(t("members.loading"))));
        region.setAttribute("aria-busy", "true");
        pager.hidden = true;
        countLine.textContent = "";
        scopeLine.textContent = "";
        return;
      }

      if (view.state === "error") {
        tbody.replaceChildren(
          messageRow(
            8,
            errorContent(t("members.errorTitle"), t("members.errorBody"), function () {
              setState("normal");
            })
          )
        );
        pager.hidden = true;
        countLine.textContent = "";
        scopeLine.textContent = "";
        return;
      }

      var rows = view.state === "empty" ? [] : filtered();
      var sorted = sortRows(rows, sortValue, view.direction);
      var total = view.state === "empty" ? 0 : records.length;
      var pageCount = Math.max(1, Math.ceil(sorted.length / view.pageSize));
      if (view.page > pageCount) {
        view.page = pageCount;
      }
      var start = (view.page - 1) * view.pageSize;
      var visible = sorted.slice(start, start + view.pageSize);

      if (visible.length === 0) {
        if (view.state === "empty") {
          tbody.replaceChildren(
            messageRow(
              8,
              emptyContent(t("members.emptyNoneTitle"), t("members.emptyNoneBody"), t("members.actionNew"), function () {
                openDialog(newDialog, newButton);
              })
            )
          );
        } else {
          tbody.replaceChildren(
            messageRow(
              8,
              emptyContent(t("members.emptyFilterTitle"), t("members.emptyFilterBody"), t("gov.clearFilters"), function () {
                resetFilters();
              })
            )
          );
        }
        pager.hidden = true;
      } else {
        renderRows(visible);
        pager.hidden = false;
        renderPages(pageCount);
        var from = start + 1;
        var to = Math.min(start + view.pageSize, sorted.length);
        rangeLine.textContent = t("gov.range", {
          from: formatInt(from),
          to: formatInt(to),
          total: formatInt(sorted.length)
        });
        pageLine.textContent = t("gov.pageOf", { page: formatInt(view.page), total: formatInt(pageCount) });
        prev.disabled = view.page === 1;
        next.disabled = view.page === pageCount;
      }

      countLine.textContent = t("members.count", {
        shown: formatInt(sorted.length),
        total: formatInt(total)
      });

      var unavailable = view.state === "partial";
      scopeLine.textContent = t("members.scope", {
        count: formatInt(sorted.length),
        savings: unavailable ? t("gov.notAvailable") : formatMoney("0"),
        loans: unavailable ? t("gov.notAvailable") : formatMoney("0")
      });

      var savingsTotal = byId("members-total-savings");
      var loansTotal = byId("members-total-loans");
      if (unavailable) {
        savingsTotal.textContent = t("gov.notAvailable");
        loansTotal.textContent = t("gov.notAvailable");
      } else {
        savingsTotal.textContent = formatMoney("0");
        loansTotal.textContent = formatMoney("0");
      }

      setAriaSort(table, view.sortKey, view.direction);
    }

    function setState(next) {
      view.state = next;
      var deniedState = next === "denied";
      content.hidden = deniedState;
      denied.hidden = !deniedState;
      readonlyBanner.hidden = next !== "readonly";
      partialBanner.hidden = next !== "partial";
      newButton.hidden = deniedState || next === "readonly";
      renderTable();
    }

    function queueFilter() {
      if (view.state !== "normal" && view.state !== "partial" && view.state !== "readonly") {
        return;
      }
      var sequence = ++filterSequence;
      region.setAttribute("aria-busy", "true");
      tbody.replaceChildren(messageRow(8, loadingContent(t("members.loading"))));
      pager.hidden = true;
      window.clearTimeout(filterTimer);
      filterTimer = window.setTimeout(function () {
        if (sequence === filterSequence) {
          renderTable();
        }
      }, 250);
    }

    function resetFilters() {
      view.query = "";
      view.status = "";
      view.branch = "";
      view.page = 1;
      search.value = "";
      statusFilter.value = "";
      branchFilter.value = "";
      renderTable();
      announce(t("gov.clearFilters"));
    }

    search.addEventListener("input", function () {
      view.query = search.value;
      view.page = 1;
      queueFilter();
    });

    search.addEventListener("keydown", function (event) {
      if (event.key === "Enter") {
        event.preventDefault();
        view.query = search.value;
        view.page = 1;
        window.clearTimeout(filterTimer);
        filterSequence += 1;
        renderTable();
      }
    });

    statusFilter.addEventListener("change", function () {
      view.status = statusFilter.value;
      view.page = 1;
      queueFilter();
    });

    branchFilter.addEventListener("change", function () {
      view.branch = branchFilter.value;
      view.page = 1;
      queueFilter();
    });

    clearButton.addEventListener("click", resetFilters);

    pageSizeSelect.addEventListener("change", function () {
      view.pageSize = Number(pageSizeSelect.value);
      view.page = 1;
      renderTable();
    });

    prev.addEventListener("click", function () {
      if (view.page > 1) {
        goToPage(view.page - 1);
      }
    });

    next.addEventListener("click", function () {
      var pageCount = Math.max(1, Math.ceil(filtered().length / view.pageSize));
      if (view.page < pageCount) {
        goToPage(view.page + 1);
      }
    });

    all("[data-gov-sort]", table).forEach(function (button) {
      button.addEventListener("click", function () {
        var key = button.getAttribute("data-gov-sort");
        if (view.sortKey === key) {
          view.direction = view.direction === "asc" ? "desc" : "asc";
        } else {
          view.sortKey = key;
          view.direction = "asc";
        }
        view.page = 1;
        renderTable();
        var label = button.querySelector("span");
        announce(
          t("gov.sorted", {
            column: label ? label.textContent : key,
            direction: t(view.direction === "asc" ? "gov.asc" : "gov.desc")
          })
        );
      });
    });

    if (newDialog) {
      newDialog.addEventListener("close", function () {
        restoreTrigger(newDialog);
      });
    }

    wireStates("members-states", setState);
    onLocale(renderTable);
    renderTable();
  }

  /* ------------------------------------------------------------------ */
  /* K-08 member file                                                    */
  /* ------------------------------------------------------------------ */

  function initMemberFile() {
    var nameNode = byId("member-name");
    if (!nameNode) {
      return;
    }

    var state = "normal";
    var nameOverride = null;
    var accounts = [
      { id: 1, product: "voluntary", status: "active" },
      { id: 2, product: "mandatory", status: "active" },
      { id: 3, product: "principal", status: "active" }
    ];
    var nextAccount = 4;
    var pendingClose = null;

    var content = byId("member-content");
    var denied = byId("member-denied");
    var errorBox = byId("member-error");
    var readonlyBanner = byId("member-readonly");
    var exitedBanner = byId("member-exited");
    var kycBanner = byId("member-kyc");
    var partialBanner = byId("member-partial");
    var editButton = byId("member-edit");
    var accountOpen = byId("account-open");
    var accountOpenNote = byId("account-open-note");
    var accountsBody = byId("accounts-tbody");
    var accountsTotal = byId("accounts-total");
    var obligationsBody = byId("obligations-tbody");
    var obligationPay = byId("obligation-pay");
    var obligationBlocked = byId("obligation-blocked");
    var obligationBlockedBody = byId("obligation-blocked-body");
    var historyBody = byId("history-tbody");
    var auditBody = byId("member-audit-tbody");
    var auditLink = byId("member-audit-link");
    var loanEmpty = byId("loan-empty");
    var loanPresent = byId("loan-present");
    var loanLoading = byId("loan-loading");
    var loanError = byId("loan-error");
    var exitButton = byId("member-exit");
    var exitBlocked = byId("exit-blocked");
    var exitDone = byId("exit-done");
    var exitLoanValue = byId("exit-loan-value");
    var exitStatusValue = byId("exit-status-value");
    var statusValue = byId("member-status");
    var kycValue = byId("member-kyc-value");

    var editDialog = byId("member-edit-dialog");
    var editName = byId("member-edit-name");
    var editNameError = byId("member-edit-name-error");
    var editSave = byId("member-edit-save");

    var openDialogNode = byId("account-open-dialog");
    var openProduct = byId("account-open-product");
    var openAmount = byId("account-open-amount");
    var openAmountError = byId("account-open-amount-error");
    var openSave = byId("account-open-save");

    var closeDialogNode = byId("account-close-dialog");
    var closeReason = byId("account-close-reason");
    var closeReasonError = byId("account-close-reason-error");
    var closeConfirm = byId("account-close-confirm");

    var payDialog = byId("obligation-pay-dialog");
    var payType = byId("obligation-pay-type");
    var payPeriod = byId("obligation-pay-period");
    var payAmount = byId("obligation-pay-amount");
    var payAmountError = byId("obligation-pay-amount-error");
    var payConfirm = byId("obligation-pay-confirm");

    var exitDialog = byId("member-exit-dialog");
    var exitReason = byId("member-exit-reason");
    var exitReasonError = byId("member-exit-reason-error");
    var exitConfirm = byId("member-exit-confirm");

    var tabLinks = all("[data-gov-tab]");
    var panels = {
      accounts: byId("panel-accounts"),
      obligations: byId("panel-obligations"),
      loans: byId("panel-loans"),
      history: byId("panel-history"),
      audit: byId("panel-audit")
    };

    function isReadOnly() {
      return state === "readonly" || state === "exited";
    }

    function isBusy() {
      return state === "loading" || state === "error";
    }

    function displayName() {
      return nameOverride === null ? t("gov.ph.member") : nameOverride;
    }

    function memberNumberValue() {
      return t("gov.ph.memberNo") + " 0042";
    }

    function renderStatus() {
      var tone = state === "exited" ? "neutral" : "success";
      var label = state === "exited" ? t("gov.status.exited") : t("gov.status.active");
      statusValue.replaceChildren(badge(tone, label));
      kycValue.textContent = state === "kyc" ? t("member.kycIncomplete") : t("member.kycVerified");
      exitStatusValue.textContent = state === "exited" ? t("gov.status.exited") : t("gov.status.active");
      exitLoanValue.textContent = state === "loan" ? t("member.exitLoanPresent") : t("member.exitNone");
    }

    function renderBanners() {
      readonlyBanner.hidden = state !== "readonly";
      exitedBanner.hidden = state !== "exited";
      kycBanner.hidden = state !== "kyc";
      partialBanner.hidden = state !== "partial";
      content.hidden = state === "denied" || state === "error";
      denied.hidden = state !== "denied";
      errorBox.hidden = state !== "error";
      if (state === "error") {
        errorBox.replaceChildren(
          errorContent(t("member.errorTitle"), t("member.errorBody"), function () {
            setState("normal");
          })
        );
      }
    }

    function renderActions() {
      var readOnly = isReadOnly();
      var busy = isBusy();
      editButton.hidden = readOnly || state === "denied" || state === "error";
      accountOpen.hidden = readOnly;
      obligationPay.hidden = readOnly || state === "empty";

      var openBlocked = state === "kyc" || busy;
      accountOpen.disabled = openBlocked;
      if (state === "kyc") {
        accountOpen.setAttribute("aria-describedby", "account-open-note");
        accountOpenNote.hidden = false;
        accountOpenNote.textContent = t("member.accountOpenBlocked");
      } else if (busy) {
        accountOpen.setAttribute("aria-describedby", "account-open-note");
        accountOpenNote.hidden = false;
        accountOpenNote.textContent = t("member.actionsPending");
      } else {
        accountOpen.removeAttribute("aria-describedby");
        accountOpenNote.hidden = true;
        accountOpenNote.textContent = "";
      }

      var payBlocked = state === "kyc" || busy;
      obligationPay.disabled = payBlocked;
      if (payBlocked) {
        obligationBlocked.hidden = false;
        obligationPay.setAttribute("aria-describedby", "obligation-blocked");
        obligationBlockedBody.textContent = state === "kyc"
          ? t("member.obligationBlockedKyc")
          : t("member.actionsPending");
      } else {
        obligationBlocked.hidden = true;
        obligationBlockedBody.textContent = "";
        obligationPay.removeAttribute("aria-describedby");
      }

      var exitHidden = readOnly || state === "denied" || busy;
      exitButton.hidden = exitHidden;
      exitDone.hidden = state !== "exited";
      if (state === "loan") {
        exitButton.disabled = true;
        exitButton.setAttribute("aria-describedby", "exit-blocked");
        exitBlocked.hidden = false;
      } else {
        exitButton.disabled = false;
        exitButton.removeAttribute("aria-describedby");
        exitBlocked.hidden = true;
      }
    }

    function accountStatusTone(status) {
      if (status === "active") {
        return "success";
      }
      if (status === "blocked") {
        return "warning";
      }
      return "neutral";
    }

    function accountStatusLabel(status) {
      if (status === "active") {
        return t("member.accountStatusActive");
      }
      if (status === "blocked") {
        return t("member.accountStatusBlocked");
      }
      return t("member.accountStatusClosed");
    }

    function renderAccounts() {
      accountsBody.replaceChildren();

      if (state === "loading") {
        accountsBody.appendChild(messageRow(6, loadingContent(t("member.loading"))));
        accountsTotal.textContent = t("gov.notAvailable");
        return;
      }

      if (state === "empty" || accounts.length === 0) {
        accountsBody.appendChild(
          messageRow(
            6,
            emptyContent(t("member.accountEmptyTitle"), t("member.accountEmptyBody"), t("member.accountOpen"), function () {
              openDialog(openDialogNode, accountOpen);
            })
          )
        );
        accountsTotal.textContent = formatMoney("0");
        return;
      }

      accounts.forEach(function (account) {
        var tr = el("tr");
        var number = el("th", "num", t("gov.ph.accountNo") + " " + pad(account.id, 2));
        number.scope = "row";
        tr.appendChild(number);
        tr.appendChild(el("td", "", t("member.product." + account.product)));
        var balance = el("td", "money-cell");
        balance.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(balance);
        var status = el("td");
        status.appendChild(badge(accountStatusTone(account.status), accountStatusLabel(account.status)));
        tr.appendChild(status);
        tr.appendChild(el("td", "", t("gov.ph.date")));
        var actions = el("td");
        if (account.status === "closed" || isReadOnly()) {
          actions.appendChild(el("span", "note", t("gov.none")));
        } else {
          var group = el("div", "gov-row-actions");
          var block = el("button", "btn btn--sm", t(account.status === "blocked" ? "member.accountUnblock" : "member.accountBlock"));
          block.type = "button";
          block.addEventListener("click", function () {
            account.status = account.status === "blocked" ? "active" : "blocked";
            renderAccounts();
            announce(t(account.status === "blocked" ? "member.accountBlockedAnnounce" : "member.accountUnblockedAnnounce"));
          });
          group.appendChild(block);

          var close = el("button", "btn btn--sm btn--danger", t("member.accountClose"));
          close.type = "button";
          close.addEventListener("click", function () {
            pendingClose = account.id;
            closeReason.value = "";
            closeReasonError.hidden = true;
            closeConfirm.disabled = true;
            openDialog(closeDialogNode, close);
          });
          group.appendChild(close);
          actions.appendChild(group);
        }
        tr.appendChild(actions);
        accountsBody.appendChild(tr);
      });

      accountsTotal.textContent = formatMoney("0");
    }

    function renderObligations() {
      obligationsBody.replaceChildren();

      if (state === "loading") {
        obligationsBody.appendChild(messageRow(7, loadingContent(t("member.loading"))));
        return;
      }

      if (state === "empty") {
        obligationsBody.appendChild(
          messageRow(
            7,
            emptyContent(t("member.obligationEmptyTitle"), t("member.obligationEmptyBody"))
          )
        );
        return;
      }

      var rows = [
        { type: "principal", period: t("member.obligationPeriodOnce") },
        { type: "mandatory", period: t("gov.ph.period") }
      ];

      rows.forEach(function (row) {
        var tr = el("tr");
        var type = el("th", "", t("member.obligationType" + (row.type === "principal" ? "Principal" : "Mandatory")));
        type.scope = "row";
        tr.appendChild(type);
        tr.appendChild(el("td", "", row.period));
        var due = el("td", "money-cell");
        due.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(due);
        var paid = el("td", "money-cell");
        paid.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(paid);
        var remaining = el("td", "money-cell");
        remaining.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(remaining);
        var status = el("td");
        status.appendChild(badge("success", t("member.obligationStatusPaid")));
        tr.appendChild(status);
        tr.appendChild(el("td", "", t("gov.ph.date")));
        obligationsBody.appendChild(tr);
      });
    }

    function renderHistory() {
      historyBody.replaceChildren();

      if (state === "loading") {
        historyBody.appendChild(messageRow(4, loadingContent(t("member.loading"))));
        return;
      }

      if (state === "empty") {
        historyBody.appendChild(
          messageRow(
            4,
            emptyContent(t("member.historyEmptyTitle"), t("member.historyEmptyBody"))
          )
        );
        return;
      }

      [1, 2, 3].forEach(function (index) {
        var tr = el("tr");
        var time = el("th", "", t("audit.timeValue"));
        time.scope = "row";
        tr.appendChild(time);
        tr.appendChild(el("td", "", t(index % 2 === 0 ? "gov.typeWithdrawal" : "gov.typeDeposit")));
        var amount = el("td", "money-cell");
        amount.appendChild(el("span", "money", formatMoney("0")));
        tr.appendChild(amount);
        tr.appendChild(el("td", "num", t("gov.ph.ref") + " " + pad(index, 3)));
        historyBody.appendChild(tr);
      });
    }

    function renderMemberAudit() {
      auditBody.replaceChildren();

      if (state === "loading") {
        auditBody.appendChild(messageRow(4, loadingContent(t("member.loading"))));
        return;
      }

      if (state === "empty") {
        auditBody.appendChild(
          messageRow(4, emptyContent(t("member.auditEmptyTitle"), t("member.auditEmptyBody")))
        );
        return;
      }

      var rows = [
        { actor: "gov.role.cashier", action: "member.auditActionOpen", reason: "gov.none" },
        { actor: "gov.role.admin", action: "member.auditActionEdit", reason: "gov.none" },
        { actor: "gov.role.admin", action: "member.auditActionBlock", reason: "gov.ph.reason" }
      ];

      rows.forEach(function (row) {
        var tr = el("tr");
        var time = el("th", "", t("audit.timeValue"));
        time.scope = "row";
        tr.appendChild(time);
        tr.appendChild(el("td", "", t(row.actor)));
        tr.appendChild(el("td", "", t(row.action)));
        tr.appendChild(el("td", "", t(row.reason)));
        auditBody.appendChild(tr);
      });

      auditLink.href = "audit.html?object=" + encodeURIComponent(memberNumberValue());
    }

    function renderLoans() {
      loanLoading.hidden = state !== "loading";
      loanError.hidden = state !== "partial";
      loanEmpty.hidden = state === "loading" || state === "partial" || state === "loan";
      loanPresent.hidden = state !== "loan";

      if (state === "partial") {
        loanError.replaceChildren(
          errorContent(t("member.loanErrorTitle"), t("member.loanErrorBody"), function () {
            setState("normal");
          })
        );
      }
    }

    function renderAll() {
      nameNode.textContent = displayName();
      byId("member-number").textContent = memberNumberValue();
      payPeriod.value = t("gov.ph.period");
      renderStatus();
      renderBanners();
      renderActions();
      renderAccounts();
      renderObligations();
      renderHistory();
      renderMemberAudit();
      renderLoans();
    }

    function setState(next) {
      state = next;
      renderAll();
    }

    function activateTab(name, focusPanel) {
      Object.keys(panels).forEach(function (key) {
        if (!panels[key]) {
          return;
        }
        panels[key].hidden = key !== name;
      });
      tabLinks.forEach(function (link) {
        if (link.getAttribute("data-gov-tab") === name) {
          link.setAttribute("aria-current", "page");
        } else {
          link.removeAttribute("aria-current");
        }
      });
      if (focusPanel && panels[name]) {
        panels[name].focus();
      }
    }

    tabLinks.forEach(function (link) {
      link.addEventListener("click", function (event) {
        event.preventDefault();
        var name = link.getAttribute("data-gov-tab");
        activateTab(name, true);
        try {
          history.replaceState(null, "", "#panel-" + name);
        } catch (error) {
          window.location.hash = "panel-" + name;
        }
      });
    });

    var initialHash = window.location.hash.replace("#", "");
    if (initialHash.indexOf("panel-") === 0) {
      var initialName = initialHash.slice(6);
      if (panels[initialName]) {
        activateTab(initialName, false);
      }
    }

    window.addEventListener("hashchange", function () {
      var hash = window.location.hash.replace("#", "");
      if (hash.indexOf("panel-") === 0 && panels[hash.slice(6)]) {
        activateTab(hash.slice(6), false);
      }
    });

    /* Edit identity */
    editButton.addEventListener("click", function () {
      editName.value = displayName();
      editNameError.hidden = true;
      editName.removeAttribute("aria-invalid");
    });

    editSave.addEventListener("click", function () {
      var value = editName.value.trim();
      if (value === "") {
        editName.setAttribute("aria-invalid", "true");
        editNameError.textContent = t("member.editNameError");
        editNameError.hidden = false;
        editName.focus();
        return;
      }
      nameOverride = value;
      nameNode.textContent = displayName();
      closeDialog(editDialog);
      announce(t("member.editDone"));
    });

    editDialog.addEventListener("close", function () {
      editNameError.hidden = true;
      editName.removeAttribute("aria-invalid");
    });

    /* Open account */
    openSave.addEventListener("click", function () {
      var raw = openAmount.value.trim();
      if (raw !== "") {
        var cents = toCents(raw);
        if (cents === null || cents <= 0n) {
          openAmount.setAttribute("aria-invalid", "true");
          openAmountError.textContent = t("member.payAmountError");
          openAmountError.hidden = false;
          openAmount.focus();
          return;
        }
      }
      accounts.push({ id: nextAccount, product: openProduct.value, status: "active" });
      nextAccount += 1;
      openAmount.value = "";
      openAmount.removeAttribute("aria-invalid");
      openAmountError.hidden = true;
      closeDialog(openDialogNode);
      if (state === "empty") {
        state = "normal";
        stateControl.set("normal");
      }
      renderAll();
      announce(t("member.openDone"));
    });

    openAmount.addEventListener("input", function () {
      openAmount.removeAttribute("aria-invalid");
      openAmountError.hidden = true;
    });

    openDialogNode.addEventListener("close", function () {
      restoreTrigger(openDialogNode);
      openAmount.value = "";
      openAmount.removeAttribute("aria-invalid");
      openAmountError.hidden = true;
    });

    /* Close account */
    closeReason.addEventListener("input", function () {
      closeConfirm.disabled = closeReason.value.trim().length < 3;
      if (!closeConfirm.disabled) {
        closeReasonError.hidden = true;
        closeReason.removeAttribute("aria-invalid");
      }
    });

    closeConfirm.addEventListener("click", function () {
      if (closeReason.value.trim().length < 3) {
        closeReason.setAttribute("aria-invalid", "true");
        closeReasonError.textContent = t("member.closeReasonError");
        closeReasonError.hidden = false;
        closeReason.focus();
        return;
      }
      var account = accounts.filter(function (item) {
        return item.id === pendingClose;
      })[0];
      if (account) {
        account.status = "closed";
      }
      pendingClose = null;
      closeDialog(closeDialogNode);
      renderAccounts();
      announce(t("member.closeDone"));
    });

    closeDialogNode.addEventListener("close", function () {
      restoreTrigger(closeDialogNode);
      closeReason.value = "";
      closeConfirm.disabled = true;
      closeReasonError.hidden = true;
      closeReason.removeAttribute("aria-invalid");
    });

    /* Record obligation payment */
    payConfirm.addEventListener("click", function () {
      var cents = toCents(payAmount.value.trim());
      if (cents === null || cents <= 0n) {
        payAmount.setAttribute("aria-invalid", "true");
        payAmountError.textContent = t("member.payAmountError");
        payAmountError.hidden = false;
        payAmount.focus();
        return;
      }
      closeDialog(payDialog);
      payAmount.value = "";
      payAmount.removeAttribute("aria-invalid");
      payAmountError.hidden = true;
      announce(t("member.payDone"));
    });

    payAmount.addEventListener("input", function () {
      payAmount.removeAttribute("aria-invalid");
      payAmountError.hidden = true;
    });

    payDialog.addEventListener("close", function () {
      payAmount.value = "";
      payAmount.removeAttribute("aria-invalid");
      payAmountError.hidden = true;
    });

    /* Exit member */
    exitReason.addEventListener("input", function () {
      exitConfirm.disabled = exitReason.value.trim().length < 3;
      if (!exitConfirm.disabled) {
        exitReasonError.hidden = true;
        exitReason.removeAttribute("aria-invalid");
      }
    });

    exitConfirm.addEventListener("click", function () {
      if (exitReason.value.trim().length < 3) {
        exitReason.setAttribute("aria-invalid", "true");
        exitReasonError.textContent = t("member.exitReasonError");
        exitReasonError.hidden = false;
        exitReason.focus();
        return;
      }
      exitConfirm.disabled = true;
      exitDialog.setAttribute("data-busy", "true");
      window.setTimeout(function () {
        exitDialog.removeAttribute("data-busy");
        closeDialog(exitDialog);
        exitReason.value = "";
        state = "exited";
        stateControl.set("exited");
        renderAll();
        announce(t("member.exitDone"));
      }, 500);
    });

    exitDialog.addEventListener("close", function () {
      exitReason.value = "";
      exitConfirm.disabled = true;
      exitReasonError.hidden = true;
      exitReason.removeAttribute("aria-invalid");
      restoreTrigger(exitDialog);
    });

    var stateControl = wireStates("member-states", setState);

    var requestedState = new URLSearchParams(window.location.search).get("state");
    var allowedStates = ["normal", "empty", "loading", "error", "partial", "readonly", "exited", "denied", "kyc", "loan"];
    if (requestedState && allowedStates.indexOf(requestedState) >= 0) {
      state = requestedState;
      stateControl.set(state);
    }

    onLocale(renderAll);
    renderAll();
  }

  /* ------------------------------------------------------------------ */
  /* K-16 report checklist                                               */
  /* ------------------------------------------------------------------ */

  function initReports() {
    var body = byId("reports-tbody");
    if (!body) {
      return;
    }

    var content = byId("reports-content");
    var denied = byId("reports-denied");
    var partialBanner = byId("reports-partial");
    var emptyBanner = byId("reports-empty");
    var scopeLine = byId("reports-scope");
    var branchSelect = byId("reports-branch");
    var state = "normal";

    var docs = [
      { key: "bs", source: "ledger", status: "available", computed: true, period: "current" },
      { key: "is", source: "journal", status: "needs_close", computed: false, period: "current" },
      { key: "equity", source: "journal", status: "needs_close", computed: false, period: "current" },
      { key: "memberRegister", source: "members", status: "not_computed", computed: false, period: "current" },
      { key: "savingsArrears", source: "obligations", status: "not_computed", computed: false, period: "current" },
      { key: "loanExposure", source: "loans", status: "needs_close", computed: false, period: "current" },
      { key: "cashRecap", source: "cash", status: "available", computed: true, period: "current" },
      { key: "closeCertificate", source: "close", status: "needs_close", computed: false, period: "current" },
      { key: "shuMember", source: "eoy", status: "not_computed", computed: false, period: "current" }
    ];
    var rowRefs = {};

    function displayStatus(doc) {
      if (state === "empty") {
        return "not_computed";
      }
      if (state === "partial" && (doc.key === "closeCertificate" || doc.key === "shuMember" || doc.key === "cashRecap")) {
        return "unknown";
      }
      return doc.status;
    }

    function statusLabel(status) {
      if (status === "available") {
        return t("reports.statusAvailable");
      }
      if (status === "needs_close") {
        return t("reports.statusNeedsClose");
      }
      if (status === "unknown") {
        return t("reports.statusUnknown");
      }
      return t("reports.statusNotComputed");
    }

    function statusClass(status) {
      if (status === "available") {
        return "gov-status-text gov-status-text--available";
      }
      if (status === "needs_close") {
        return "gov-status-text gov-status-text--needs";
      }
      if (status === "unknown") {
        return "gov-status-text gov-status-text--unknown";
      }
      return "gov-status-text gov-status-text--not";
    }

    function computedLabel(doc) {
      if (displayStatus(doc) === "unknown") {
        return t("gov.notAvailable");
      }
      if (state === "empty" || !doc.computed) {
        return t("reports.notComputed");
      }
      return t("reports.computedAt");
    }

    function updateRow(doc) {
      var refs = rowRefs[doc.key];
      if (!refs) {
        return;
      }
      var status = displayStatus(doc);
      refs.status.textContent = statusLabel(status);
      refs.status.className = statusClass(status);
      refs.computed.textContent = computedLabel(doc);
    }

    function renderRows() {
      body.replaceChildren();
      rowRefs = {};

      docs.forEach(function (doc) {
        var tr = el("tr");
        var name = el("th", "", t("reports.doc." + doc.key));
        name.scope = "row";
        tr.appendChild(name);

        var periodCell = el("td");
        var select = el("select", "select gov-period-select");
        select.setAttribute("data-doc-period", doc.key);
        select.setAttribute("aria-label", t("reports.periodFor", { doc: t("reports.doc." + doc.key) }));
        [
          { value: "current", key: "reports.periodCurrent" },
          { value: "previous", key: "reports.periodPrevious" }
        ].forEach(function (option) {
          var node = el("option", "", t(option.key));
          node.value = option.value;
          select.appendChild(node);
        });
        select.value = doc.period;
        select.addEventListener("change", function () {
          doc.period = select.value;
          doc.status = "not_computed";
          doc.computed = false;
          updateRow(doc);
          announce(t("reports.periodChanged"));
        });
        periodCell.appendChild(select);
        tr.appendChild(periodCell);

        tr.appendChild(el("td", "", t("reports.source." + doc.source)));

        var computed = el("td", "", computedLabel(doc));
        tr.appendChild(computed);

        var status = el("span", statusClass(displayStatus(doc)), statusLabel(displayStatus(doc)));
        var statusCell = el("td");
        statusCell.appendChild(status);
        tr.appendChild(statusCell);

        var actionCell = el("td");
        if (doc.key === "bs") {
          var link = el("a", "btn btn--sm", t("reports.open"));
          link.href = "laporan-neraca.html";
          actionCell.appendChild(link);
        } else {
          var disabled = el("button", "btn btn--sm", t("reports.open"));
          disabled.type = "button";
          disabled.disabled = true;
          disabled.setAttribute("aria-describedby", "reports-note");
          actionCell.appendChild(disabled);
        }
        tr.appendChild(actionCell);

        rowRefs[doc.key] = { computed: computed, status: status };
        body.appendChild(tr);
      });
    }

    function render() {
      var deniedState = state === "denied";
      content.hidden = deniedState;
      denied.hidden = !deniedState;
      partialBanner.hidden = state !== "partial";
      emptyBanner.hidden = state !== "empty";
      branchSelect.disabled = deniedState;

      if (deniedState) {
        return;
      }

      if (state === "loading") {
        body.replaceChildren(messageRow(6, loadingContent(t("reports.loading"))));
      } else if (state === "error") {
        body.replaceChildren(
          messageRow(6, errorContent(t("reports.errorTitle"), t("reports.errorBody"), function () {
            setState("normal");
          }))
        );
      } else {
        renderRows();
      }

      scopeLine.textContent = t("reports.scope", {
        branch: t("gov.branch." + branchSelect.value)
      });
    }

    function setState(next) {
      state = next;
      render();
    }

    branchSelect.addEventListener("change", function () {
      docs.forEach(function (doc) {
        doc.status = "not_computed";
        doc.computed = false;
      });
      render();
      announce(t("reports.branchChanged"));
    });

    wireStates("reports-states", setState);

    onLocale(render);
    render();
  }

  /* ------------------------------------------------------------------ */
  /* K-16 balance sheet document                                         */
  /* ------------------------------------------------------------------ */

  function initBalanceSheet() {
    var table = byId("bs-table");
    if (!table) {
      return;
    }

    var state = "normal";
    var documentNode = byId("bs-document");
    var actions = byId("bs-actions");
    var denied = byId("bs-denied");
    var data = byId("bs-data");
    var loading = byId("bs-loading");
    var error = byId("bs-error");
    var empty = byId("bs-empty");
    var watermark = byId("bs-watermark");
    var openNote = byId("bs-open-note");
    var closedNote = byId("bs-closed-note");
    var unbalancedAlert = byId("bs-unbalanced-alert");
    var partialBanner = byId("bs-partial");
    var verdictOk = byId("bs-verdict-ok");
    var verdictFail = byId("bs-verdict-fail");
    var difference = byId("bs-difference");
    var signatures = byId("bs-signatures");
    var generated = byId("bs-generated");
    var printButton = byId("bs-print");

    function render() {
      var deniedState = state === "denied";
      var dataVisible = state === "normal" || state === "closed" || state === "unbalanced";
      var failed = state === "error" || state === "partial";

      documentNode.hidden = deniedState;
      actions.hidden = deniedState;
      denied.hidden = !deniedState;
      data.hidden = !dataVisible;
      loading.hidden = state !== "loading";
      error.hidden = !failed;
      empty.hidden = state !== "empty";
      signatures.hidden = !dataVisible;
      watermark.hidden = state === "closed" || deniedState;
      openNote.hidden = state === "closed" || deniedState;
      closedNote.hidden = state !== "closed";
      unbalancedAlert.hidden = state !== "unbalanced";
      partialBanner.hidden = state !== "partial";
      verdictOk.hidden = state === "unbalanced";
      verdictFail.hidden = state !== "unbalanced";
      generated.textContent = state === "empty" || state === "loading"
        ? t("reports.notComputed")
        : t("reports.computedAt");
      difference.textContent = state === "unbalanced" ? t("gov.ph.difference") : formatMoney("0");

      if (failed) {
        error.replaceChildren(
          errorContent(t("report.bs.errorTitle"), t("report.bs.errorBody"), function () {
            setState("normal");
          })
        );
      }
    }

    function setState(next) {
      state = next;
      render();
    }

    printButton.addEventListener("click", function () {
      window.print();
    });

    wireStates("bs-states", setState);
    onLocale(render);
    render();
  }

  /* ------------------------------------------------------------------ */
  /* K-17 audit viewer                                                   */
  /* ------------------------------------------------------------------ */

  function initAudit() {
    var table = byId("audit-table");
    if (!table) {
      return;
    }

    var region = byId("audit-region");
    var body = byId("audit-tbody");
    var countLine = byId("audit-count");
    var scopeLine = byId("audit-scope");
    var totalCell = byId("audit-total");
    var pager = byId("audit-pager");
    var rangeLine = byId("audit-range");
    var pageLine = byId("audit-page-label");
    var pagesBox = byId("audit-pages");
    var prev = byId("audit-prev");
    var next = byId("audit-next");
    var pageSizeSelect = byId("audit-page-size");
    var search = byId("audit-search");
    var actorFilter = byId("audit-actor");
    var actionFilter = byId("audit-action");
    var fromFilter = byId("audit-from");
    var toFilter = byId("audit-to");
    var clearButton = byId("audit-clear");
    var content = byId("audit-content");
    var denied = byId("audit-denied");
    var partialBanner = byId("audit-partial");
    var detailDialog = byId("audit-detail-dialog");
    var detailBody = byId("audit-detail-body");

    var view = {
      state: "normal",
      query: "",
      actor: "",
      action: "",
      from: "",
      to: "",
      page: 1,
      pageSize: 50,
      direction: "desc"
    };
    var filterTimer = null;
    var filterSequence = 0;
    var currentDetail = null;

    var actors = ["cashier", "admin", "board", "supervisor"];
    var actions = ["deposit", "withdrawal", "accountOpen", "accountBlock", "param", "loanApprove", "close"];
    var rows = [];
    for (var index = 1; index <= 64; index += 1) {
      var action = actions[(index - 1) % actions.length];
      var needsReason = action === "param" || action === "accountBlock" || action === "close";
      rows.push({
        order: index,
        iso: "2026-11-0" + (((index - 1) % 5) + 1),
        actor: actors[(index - 1) % actors.length],
        action: action,
        entity: index % 3 === 0 ? "account" : index % 3 === 1 ? "member" : "reference",
        number: index,
        hasReason: needsReason
      });
    }

    var actorKey = {
      cashier: "audit.actorCashier",
      admin: "audit.actorAdmin",
      board: "audit.actorBoard",
      supervisor: "audit.actorSupervisor"
    };

    var actionKey = {
      deposit: "audit.actionDeposit",
      withdrawal: "audit.actionWithdrawal",
      accountOpen: "audit.actionAccountOpen",
      accountBlock: "audit.actionAccountBlock",
      param: "audit.actionParam",
      loanApprove: "audit.actionLoanApprove",
      close: "audit.actionClose"
    };

    function entityLabel(row) {
      if (row.entity === "account") {
        return t("gov.ph.accountNo") + " " + pad(row.number, 2);
      }
      if (row.entity === "reference") {
        return t("gov.ph.ref") + " " + pad(row.number, 3);
      }
      return t("gov.ph.memberNo") + " " + pad(row.number, 4);
    }

    function referenceLabel(row) {
      return t("gov.ph.ref") + " " + pad(row.order, 3);
    }

    function actorLabel(row) {
      return t(actorKey[row.actor]);
    }

    function actionLabel(row) {
      return t(actionKey[row.action]);
    }

    function hasFilters() {
      return view.query.trim() !== "" || view.actor !== "" || view.action !== "" || view.from !== "" || view.to !== "";
    }

    function filtered() {
      var query = view.query.trim().toLowerCase();
      return rows.filter(function (row) {
        var text = (entityLabel(row) + " " + referenceLabel(row) + " " + actionLabel(row)).toLowerCase();
        var matchesQuery = query === "" || text.indexOf(query) >= 0;
        var matchesActor = view.actor === "" || row.actor === view.actor;
        var matchesAction = view.action === "" || row.action === view.action;
        var matchesFrom = view.from === "" || row.iso >= view.from;
        var matchesTo = view.to === "" || row.iso <= view.to;
        return matchesQuery && matchesActor && matchesAction && matchesFrom && matchesTo;
      });
    }

    function renderPages(pageCount) {
      pagesBox.replaceChildren();
      for (var page = 1; page <= pageCount; page += 1) {
        (function (pageNumber) {
          pagesBox.appendChild(
            pageButton(formatInt(pageNumber), pageNumber === view.page, pageNumber, function () {
              goToPage(pageNumber);
            })
          );
        })(page);
      }
    }

    function goToPage(pageNumber) {
      view.page = pageNumber;
      renderTable();
      var target = pagesBox.querySelector('[data-page="' + pageNumber + '"]');
      if (target) {
        target.focus();
      }
      announce(t("gov.pageAnnounce", { page: formatInt(pageNumber), range: rangeLine.textContent }));
    }

    function renderRows(visible) {
      body.replaceChildren();
      visible.forEach(function (row) {
        var tr = el("tr");
        var time = el("th", "", t("audit.timeValue"));
        time.scope = "row";
        tr.appendChild(time);
        tr.appendChild(el("td", "", actorLabel(row)));
        tr.appendChild(el("td", "", actionLabel(row)));
        tr.appendChild(el("td", "num", entityLabel(row)));
        tr.appendChild(el("td", "", row.hasReason ? t("gov.ph.reason") : t("audit.reasonNone")));
        tr.appendChild(el("td", "num", referenceLabel(row)));
        var action = el("td");
        var open = el("button", "btn btn--sm", t("audit.open"));
        open.type = "button";
        open.addEventListener("click", function () {
          openDetail(row, open);
        });
        action.appendChild(open);
        tr.appendChild(action);
        body.appendChild(tr);
      });
      totalCell.textContent = formatInt(visible.length);
    }

    function renderTable() {
      region.removeAttribute("aria-busy");

      if (view.state === "loading") {
        body.replaceChildren(messageRow(7, loadingContent(t("audit.loading"))));
        region.setAttribute("aria-busy", "true");
        pager.hidden = true;
        countLine.textContent = "";
        scopeLine.textContent = "";
        totalCell.textContent = "0";
        return;
      }

      if (view.state === "error") {
        body.replaceChildren(
          messageRow(7, errorContent(t("audit.errorTitle"), t("audit.errorBody"), function () {
            setState("normal");
          }))
        );
        pager.hidden = true;
        countLine.textContent = "";
        scopeLine.textContent = "";
        totalCell.textContent = "0";
        return;
      }

      var list = view.state === "empty" ? [] : filtered();
      var sorted = sortRows(list, function (row) {
        return row.order;
      }, view.direction);
      var pageCount = Math.max(1, Math.ceil(sorted.length / view.pageSize));
      if (view.page > pageCount) {
        view.page = pageCount;
      }
      var start = (view.page - 1) * view.pageSize;
      var visible = sorted.slice(start, start + view.pageSize);

      if (visible.length === 0) {
        var title = view.state === "empty" ? t("audit.emptyTitle") : t("audit.filteredTitle");
        var copy = view.state === "empty" ? t("audit.emptyBody") : t("audit.filteredBody");
        body.replaceChildren(messageRow(7, emptyContent(title, copy, hasFilters() ? t("gov.clearFilters") : null, hasFilters() ? resetFilters : null)));
        pager.hidden = true;
        totalCell.textContent = "0";
      } else {
        renderRows(visible);
        pager.hidden = false;
        renderPages(pageCount);
        var from = start + 1;
        var to = Math.min(start + view.pageSize, sorted.length);
        rangeLine.textContent = t("gov.range", {
          from: formatInt(from),
          to: formatInt(to),
          total: formatInt(sorted.length)
        });
        pageLine.textContent = t("gov.pageOf", { page: formatInt(view.page), total: formatInt(pageCount) });
        prev.disabled = view.page === 1;
        next.disabled = view.page === pageCount;
      }

      countLine.textContent = t("audit.count", {
        shown: formatInt(sorted.length),
        total: formatInt(view.state === "empty" ? 0 : rows.length)
      });
      scopeLine.textContent = t("audit.scope", { count: formatInt(sorted.length) });
      setAriaSort(table, "time", view.direction);
    }

    function setState(next) {
      view.state = next;
      var deniedState = next === "denied";
      content.hidden = deniedState;
      denied.hidden = !deniedState;
      partialBanner.hidden = next !== "partial";
      renderTable();
    }

    function queueFilter() {
      if (view.state !== "normal" && view.state !== "partial") {
        return;
      }
      var sequence = ++filterSequence;
      region.setAttribute("aria-busy", "true");
      body.replaceChildren(messageRow(7, loadingContent(t("audit.loading"))));
      pager.hidden = true;
      window.clearTimeout(filterTimer);
      filterTimer = window.setTimeout(function () {
        if (sequence === filterSequence) {
          renderTable();
        }
      }, 250);
    }

    function resetFilters() {
      view.query = "";
      view.actor = "";
      view.action = "";
      view.from = "";
      view.to = "";
      view.page = 1;
      search.value = "";
      actorFilter.value = "";
      actionFilter.value = "";
      fromFilter.value = "";
      toFilter.value = "";
      renderTable();
      announce(t("gov.clearFilters"));
    }

    function openDetail(row, trigger) {
      currentDetail = row;
      var facts = el("dl", "facts");
      function fact(label, value, className) {
        facts.appendChild(el("dt", "", label));
        var dd = el("dd", className || "", value);
        facts.appendChild(dd);
        return dd;
      }
      fact(t("audit.detailTime"), t("audit.timeValue"), "num");
      fact(t("audit.detailActor"), actorLabel(row));
      fact(t("audit.detailAction"), actionLabel(row));
      fact(t("audit.detailObject"), entityLabel(row), "num");
      fact(t("audit.detailReason"), row.hasReason ? t("gov.ph.reason") : t("audit.reasonNone"));
      var refValue = fact(t("audit.detailRef"), referenceLabel(row), "num");
      refValue.id = "audit-detail-ref";

      var diff = el("div", "stack-sm");
      diff.appendChild(el("p", "gov-control-label", t("audit.detailChange")));
      var diffList = el("dl", "stack-sm");
      var before = el("div", "amount-line");
      before.appendChild(el("dt", "", t("audit.detailBefore")));
      before.appendChild(el("dd", "", t("gov.ph.valueBefore")));
      diffList.appendChild(before);
      var after = el("div", "amount-line");
      after.appendChild(el("dt", "", t("audit.detailAfter")));
      after.appendChild(el("dd", "", t("gov.ph.valueAfter")));
      diffList.appendChild(after);
      diff.appendChild(diffList);

      detailBody.replaceChildren(facts, diff);
      openDialog(detailDialog, trigger);
    }

    detailDialog.addEventListener("close", function () {
      restoreTrigger(detailDialog);
      currentDetail = null;
    });

    search.addEventListener("input", function () {
      view.query = search.value;
      view.page = 1;
      queueFilter();
    });

    search.addEventListener("keydown", function (event) {
      if (event.key === "Enter") {
        event.preventDefault();
        view.query = search.value;
        view.page = 1;
        window.clearTimeout(filterTimer);
        filterSequence += 1;
        renderTable();
      }
    });

    actorFilter.addEventListener("change", function () {
      view.actor = actorFilter.value;
      view.page = 1;
      queueFilter();
    });

    actionFilter.addEventListener("change", function () {
      view.action = actionFilter.value;
      view.page = 1;
      queueFilter();
    });

    fromFilter.addEventListener("change", function () {
      view.from = fromFilter.value;
      view.page = 1;
      queueFilter();
    });

    toFilter.addEventListener("change", function () {
      view.to = toFilter.value;
      view.page = 1;
      queueFilter();
    });

    clearButton.addEventListener("click", resetFilters);

    pageSizeSelect.addEventListener("change", function () {
      view.pageSize = Number(pageSizeSelect.value);
      view.page = 1;
      renderTable();
    });

    prev.addEventListener("click", function () {
      if (view.page > 1) {
        goToPage(view.page - 1);
      }
    });

    next.addEventListener("click", function () {
      var pageCount = Math.max(1, Math.ceil(filtered().length / view.pageSize));
      if (view.page < pageCount) {
        goToPage(view.page + 1);
      }
    });

    all("[data-gov-sort]", table).forEach(function (button) {
      button.addEventListener("click", function () {
        view.direction = view.direction === "asc" ? "desc" : "asc";
        view.page = 1;
        renderTable();
        announce(
          t("gov.sorted", {
            column: t("audit.colTime"),
            direction: t(view.direction === "asc" ? "gov.asc" : "gov.desc")
          })
        );
      });
    });

    var objectParam = new URLSearchParams(window.location.search).get("object");
    if (objectParam) {
      search.value = objectParam;
      view.query = objectParam;
    }

    onLocale(function () {
      renderTable();
      if (detailDialog.open && currentDetail) {
        openDetail(currentDetail, detailDialog.__govTrigger);
      }
    });

    wireStates("audit-states", setState);
    renderTable();
  }

  /* ------------------------------------------------------------------ */
  /* Boot                                                                */
  /* ------------------------------------------------------------------ */

  initMembers();
  initMemberFile();
  initReports();
  initBalanceSheet();
  initAudit();
})();
