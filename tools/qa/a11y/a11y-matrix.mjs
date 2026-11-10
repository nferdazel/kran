#!/usr/bin/env node
/**
 * Accessibility gate matrix runner (Playwright + axe).
 *
 * Runs one axe analysis per screen x theme x width combination, scoped to the
 * screen region so document chrome (notes, captions) cannot hide or fake results.
 * A combination only PASSes when all three hold: the screen really rendered,
 * the requested theme/width really applied, and no moderate+ violation exists.
 *
 * Exit codes: 0 all PASS, 1 any FAIL (gate not green), 2 only BLOCKED combos.
 *
 * Usage:
 *   node tools/qa/a11y/a11y-matrix.mjs --config mockup
 *   node tools/qa/a11y/a11y-matrix.mjs --config app --url http://127.0.0.1:5173 \
 *        --fixtures .local/qa/fixtures.json --label gate-t285
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");
const GATE_IMPACTS = new Set(["critical", "serious", "moderate"]);
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const out = { flags: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      out.flags[key] = true;
    } else {
      out.flags[key] = next;
      i += 1;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.flags.config) {
  console.error("Missing --config <name|path>. Try: --config mockup");
  process.exit(64);
}

function resolveConfig(name) {
  const candidates = [
    name,
    path.join(HERE, "config", `${name}.json`),
    path.join(REPO, name),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return path.resolve(candidate);
  }
  throw new Error(`Config not found: ${name}`);
}

const cfgPath = resolveConfig(args.flags.config);
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));

const label = args.flags.label ?? cfg.label ?? path.basename(cfgPath, ".json");
const outDir = path.resolve(REPO, args.flags.out ?? cfg.out ?? ".local/qa/results");
const modulesDir = path.resolve(REPO, cfg.modulesDir ?? "apps/web/node_modules");
const widths = args.flags.widths
  ? String(args.flags.widths).split(",").map(Number)
  : cfg.widths ?? [1440, 360];
const themes = args.flags.themes
  ? String(args.flags.themes).split(",")
  : cfg.themes ?? ["light", "dark"];
const only = args.flags.only ? String(args.flags.only).split(",") : null;

let fixtures = { ...(cfg.fixtures ?? {}) };
if (args.flags.fixtures) {
  const fixturePath = path.resolve(REPO, args.flags.fixtures);
  fixtures = { ...fixtures, ...JSON.parse(fs.readFileSync(fixturePath, "utf8")) };
}

const baseUrl = args.flags.url ?? cfg.url;
if (!baseUrl || baseUrl.includes("REPLACE_ME")) {
  console.error(`Config ${cfgPath} has no usable url; pass --url.`);
  process.exit(64);
}

// ---------------------------------------------------------------- modules

async function loadModule(dir, relatives, what) {
  for (const rel of relatives) {
    const candidate = path.join(dir, rel);
    if (fs.existsSync(candidate)) return import(pathToFileURL(candidate).href);
  }
  throw new Error(
    `${what} not found in ${dir}. Run "pnpm install" in apps/web (no new dependency needed).`,
  );
}

const { chromium } = await loadModule(
  modulesDir,
  ["@playwright/test/index.mjs", "@playwright/test/index.js", "playwright/index.mjs", "playwright/index.js"],
  "Playwright",
);
const { default: AxeBuilder } = await loadModule(
  modulesDir,
  ["@axe-core/playwright/dist/index.mjs", "@axe-core/playwright/dist/index.js"],
  "axe (@axe-core/playwright)",
);

// ---------------------------------------------------------------- helpers

function routeFor(screen) {
  const route = screen.route ?? "";
  const missing = [];
  const resolved = route.replace(/\{(\w+)\}/g, (_, key) => {
    const value = fixtures[key];
    if (value === undefined || value === null || value === "") {
      missing.push(key);
      return `{${key}}`;
    }
    return encodeURIComponent(String(value));
  });
  return { route: resolved, missing };
}

function comboId(id, theme, width) {
  return `${id}__${theme}__${width}`;
}

/** Fill `{theme}` / `{width}` placeholders inside configured selectors. */
function fillSelector(selector, vars) {
  return String(selector).replace(/\{(\w+)\}/g, (_, key) =>
    vars[key] === undefined ? `{${key}}` : String(vars[key]),
  );
}

function trimTarget(target) {
  return Array.isArray(target) ? target.join(" ") : String(target);
}

function firstLine(text) {
  return String(text ?? "").split("\n").find((line) => line.trim().length > 0) ?? "";
}

function formatViolation(violation) {
  return {
    id: violation.id,
    impact: violation.impact,
    help: violation.help,
    nodes: violation.nodes.length,
    targets: violation.nodes.slice(0, 5).map((node) => trimTarget(node.target)),
    summary: firstLine(violation.nodes[0]?.failureSummary),
  };
}

// ---------------------------------------------------------------- run

const startedAt = new Date();
const results = [];
let hardFailures = 0;
let blocked = 0;

const browser = await chromium.launch();

for (const screen of cfg.screens) {
  if (only && !only.includes(screen.id)) continue;

  const { route, missing } = routeFor(screen);

  for (const theme of themes) {
    for (const width of widths) {
      const record = {
        combo: comboId(screen.id, theme, width),
        screen: screen.id,
        k: screen.k ?? [],
        route,
        theme,
        width,
        verdict: "FAIL",
        reason: null,
        scopeNodes: 0,
        violations: [],
        minor: [],
        outOfScope: [],
        consoleErrors: [],
        axes: {},
        durationMs: 0,
      };
      const started = Date.now();

      if (missing.length > 0) {
        record.verdict = "BLOCKED";
        record.reason = `missing fixture(s): ${missing.join(", ")}`;
        blocked += 1;
        results.push(record);
        continue;
      }

      const pageWidth = cfg.axes?.width?.mode === "viewport" ? width : cfg.viewport?.width ?? 1440;
      process.stdout.write(`[run] ${record.combo} ... `);
      const context = await browser.newContext({
        viewport: { width: pageWidth, height: cfg.viewport?.height ?? 1000 },
        colorScheme: theme === "dark" ? "dark" : "light",
        reducedMotion: "reduce",
        locale: cfg.locale ?? "id-ID",
      });

      try {
        if (cfg.axes?.theme?.mode === "storage" && cfg.axes.theme.storageKey) {
          await context.addInitScript(
            ([key, value]) => {
              try {
                localStorage.setItem(key, value);
              } catch {
                /* storage may be blocked; the assertion below catches it */
              }
            },
            [cfg.axes.theme.storageKey, theme],
          );
        }

        const page = await context.newPage();
        page.on("pageerror", (error) => record.consoleErrors.push(`pageerror: ${error.message}`));
        page.on("console", (message) => {
          if (message.type() === "error") record.consoleErrors.push(`console: ${message.text()}`);
        });

        const target = route.startsWith("/") ? new URL(route, baseUrl).href : baseUrl;
        const response = await page.goto(target, { waitUntil: "load", timeout: 30000 });
        if (response && response.status() >= 400) {
          throw new Error(`HTTP ${response.status()} for ${target}`);
        }

        if (cfg.auth?.required) {
          await page.waitForLoadState("networkidle").catch(() => {});
          const landed = new URL(page.url()).pathname;
          if (landed !== screen.route && (cfg.auth.redirectPath ?? "/login") === landed) {
            record.verdict = "BLOCKED";
            record.reason = `redirected to ${landed}; no authenticated session`;
            blocked += 1;
            results.push(record);
            continue;
          }
        }

        // Scope root: the region that is actually being judged. Controls that
        // switch a single screen live in the document, so they are resolved
        // inside controlScope (the screen's own section) instead of page-wide.
        const scope = screen.scope ?? cfg.scope ?? "body";
        await page.waitForSelector(scope, { state: "attached", timeout: 10000 });
        const host = screen.controlScope ? page.locator(screen.controlScope).first() : page;

        // --- theme axis
        const themeAxis = cfg.axes?.theme ?? { mode: "none" };
        if (themeAxis.mode === "control") {
          const control = host
            .locator(fillSelector(themeAxis.control ?? `[data-theme-btn="${theme}"]`, { theme }))
            .first();
          await control.click();
        }
        if (themeAxis.mode === "html") {
          await page.evaluate((value) => {
            document.documentElement.setAttribute("data-theme", value);
          }, theme);
        }
        const themeRead = await page.evaluate(
          ([selector, attr, root]) => {
            const node = document.querySelector(root) ?? document.documentElement;
            return node.getAttribute(attr);
          },
          [themeAxis.control, themeAxis.attr ?? "data-theme", themeAxis.readFrom ?? scope],
        );
        record.axes.theme = themeAxis.mode === "none" ? "n/a" : String(themeRead);
        if (themeAxis.mode !== "none" && themeRead !== theme) {
          throw new Error(
            `theme did not apply: wanted ${theme}, ${themeAxis.attr ?? "data-theme"}="${themeRead}"`,
          );
        }

        // --- width axis
        const widthAxis = cfg.axes?.width ?? { mode: "viewport" };
        if (widthAxis.mode === "control") {
          const control = host
            .locator(fillSelector(widthAxis.control ?? `[data-w-btn="${width}"]`, { width }))
            .first();
          await control.click();
          await page.waitForTimeout(80);
        }
        if (widthAxis.mode === "control") {
          const widthRead = await page.evaluate(
            ([root, attr]) => document.querySelector(root)?.getAttribute(attr),
            [widthAxis.readFrom ?? scope, widthAxis.attr ?? "data-w"],
          );
          record.axes.width = String(widthRead);
          if (widthRead !== String(width)) {
            throw new Error(
              `width did not apply: wanted ${width}, ${widthAxis.attr ?? "data-w"}="${widthRead}"`,
            );
          }
        } else {
          record.axes.width = String(pageWidth);
        }

        // --- screen-specific setup (state variants such as an open drawer)
        for (const step of screen.setup ?? []) {
          if (step.click) {
            const stepHost = step.within === "page" ? page : host;
            await stepHost.locator(step.click).first().click();
            await page.waitForTimeout(step.wait ?? 60);
          }
          if (step.waitFor) {
            await page.waitForSelector(step.waitFor, { state: step.state ?? "visible" });
          }
        }

        // --- the screen must really be there, with content
        const expectSelector = screen.expect?.selector;
        if (!expectSelector) throw new Error("config: screen.expect.selector is required");
        const count = await page.locator(expectSelector).count();
        const min = screen.expect.min ?? 1;
        record.scopeNodes = count;
        if (count < min) {
          throw new Error(`screen not rendered: ${expectSelector} = ${count}, expected >= ${min}`);
        }
        if (screen.expect.visible) {
          const visible = await page.locator(screen.expect.visible).first().isVisible();
          if (!visible) throw new Error(`screen content not visible: ${screen.expect.visible}`);
        }

        // --- axe, scoped
        const axe = await new AxeBuilder({ page }).include(scope).withTags(AXE_TAGS).analyze();
        for (const violation of axe.violations) {
          const formatted = formatViolation(violation);
          if (GATE_IMPACTS.has(violation.impact)) record.violations.push(formatted);
          else record.minor.push(formatted);
        }

        // --- axe outside the judged scope, so document chrome is recorded, not ignored
        if (cfg.reportOutOfScope !== false) {
          const outside = await new AxeBuilder({ page })
            .exclude(scope)
            .withTags(AXE_TAGS)
            .analyze()
            .catch(() => null);
          if (outside) record.outOfScope = outside.violations.map(formatViolation);
        }

        if (record.violations.length > 0) {
          record.reason = `${record.violations.length} moderate+ violation(s)`;
        } else {
          record.verdict = "PASS";
          record.reason = record.minor.length > 0 ? `${record.minor.length} minor (not gating)` : null;
        }
      } catch (error) {
        record.verdict = "FAIL";
        record.reason = error.message.split("\n")[0];
        record.errorDetail = error.message.split("\n").slice(0, 12).join("\n");
      } finally {
        record.durationMs = Date.now() - started;
        await context.close().catch(() => {});
        process.stdout.write(
          `${record.verdict} (${record.violations.length} gate, ${record.minor.length} minor, ${record.durationMs}ms)${record.reason ? ` - ${record.reason}` : ""}\n`,
        );
      }

      if (record.verdict === "FAIL") hardFailures += 1;
      results.push(record);
    }
  }
}

await browser.close();

// ---------------------------------------------------------------- report

const summary = {
  label,
  target: baseUrl,
  config: path.relative(REPO, cfgPath),
  startedAt: startedAt.toISOString(),
  finishedAt: new Date().toISOString(),
  node: process.version,
  themes,
  widths,
  gateImpacts: [...GATE_IMPACTS],
  counts: {
    combos: results.length,
    pass: results.filter((r) => r.verdict === "PASS").length,
    fail: results.filter((r) => r.verdict === "FAIL").length,
    blocked: results.filter((r) => r.verdict === "BLOCKED").length,
    violations: results.reduce((sum, r) => sum + r.violations.length, 0),
    minor: results.reduce((sum, r) => sum + r.minor.length, 0),
  },
  exitCode: hardFailures > 0 ? 1 : blocked > 0 ? 2 : 0,
  combos: results,
};

fs.mkdirSync(outDir, { recursive: true });
const jsonPath = path.join(outDir, `${label}.json`);
fs.writeFileSync(jsonPath, `${JSON.stringify(summary, null, 2)}\n`);

const lines = [];
lines.push(`# A11y matrix - ${label}`);
lines.push("");
lines.push(`- Target: \`${baseUrl}\``);
lines.push(`- Config: \`${summary.config}\``);
lines.push(`- Run: ${summary.startedAt} -> ${summary.finishedAt}`);
lines.push(`- Gate: axe ${AXE_TAGS.join(", ")}; gating impacts ${[...GATE_IMPACTS].join(", ")}`);
lines.push(
  `- Totals: ${summary.counts.combos} combos, ${summary.counts.pass} PASS, ${summary.counts.fail} FAIL, ` +
    `${summary.counts.blocked} BLOCKED, ${summary.counts.violations} gating violation(s), ${summary.counts.minor} minor`,
);
lines.push(`- Exit code: ${summary.exitCode}`);
lines.push("");
lines.push("| Combo | K | Theme | Axis width | Scope nodes | Moderate+ | Minor | Verdict | Note |");
lines.push("|---|---|---|---|---|---|---|---|---|");
for (const r of results) {
  lines.push(
    `| ${r.combo} | ${r.k.join(", ") || "-"} | ${r.theme} | ${r.axes.width ?? r.width} | ${r.scopeNodes} | ` +
      `${r.violations.length} | ${r.minor.length} | ${r.verdict} | ${r.reason ?? ""} |`,
  );
}

const withViolations = results.filter((r) => r.violations.length > 0 || r.minor.length > 0);
if (withViolations.length > 0) {
  lines.push("", "## Findings", "");
  for (const r of withViolations) {
    lines.push(`### ${r.combo}`, "");
    for (const v of [...r.violations, ...r.minor]) {
      lines.push(
        `- **${v.id}** (${v.impact}, ${v.nodes} node${v.nodes > 1 ? "s" : ""}) - ${v.help}`,
      );
      lines.push(`  - first node: \`${v.targets[0] ?? "-"}\``);
      if (v.summary) lines.push(`  - ${v.summary}`);
    }
    lines.push("");
  }
}

const outOfScope = results.filter((r) => r.outOfScope.length > 0);
if (outOfScope.length > 0) {
  lines.push("## Outside the judged scope (mockup/document chrome)", "");
  const seen = new Map();
  for (const r of outOfScope) {
    for (const v of r.outOfScope) {
      const key = `${v.id}|${v.targets[0] ?? ""}`;
      if (seen.has(key)) continue;
      seen.set(key, true);
      lines.push(`- **${v.id}** (${v.impact}) at \`${v.targets[0] ?? "-"}\` - seen in ${r.combo}`);
    }
  }
  lines.push("");
}

const failures = results.filter((r) => r.verdict === "FAIL");
if (failures.length > 0) {
  lines.push("## FAIL detail", "");
  for (const r of failures) {
    lines.push(`- \`${r.combo}\`: ${r.reason}`);
    for (const error of r.consoleErrors.slice(0, 3)) lines.push(`  - ${error}`);
  }
  lines.push("");
}

const mdPath = path.join(outDir, `${label}.md`);
fs.writeFileSync(mdPath, `${lines.join("\n")}\n`);

console.log(`${label}: ${summary.counts.combos} combos -> ${summary.counts.pass} PASS, ` +
  `${summary.counts.fail} FAIL, ${summary.counts.blocked} BLOCKED, ${summary.counts.violations} gating violation(s)`);
console.log(`json: ${path.relative(REPO, jsonPath)}`);
console.log(`md:   ${path.relative(REPO, mdPath)}`);
for (const r of failures) console.log(`FAIL ${r.combo}: ${r.reason}`);

process.exit(summary.exitCode);
