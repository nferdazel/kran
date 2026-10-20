## Repositori posting rule (T-074). SQL murni; pemilihan rule ada di domain.

import std/[json, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/[coa, posting]

proc ruleOf(row: Row): PostingRule =
  PostingRule(
    ruleId: Id(row[0]),
    eventType: row[1],
    productCode: row[2],
    conditions: parseJson(row[3]),
    priority: parseInt(row[4]))

proc linesOf(db: DbConn, ruleId: Id): seq[PostingRuleLine] =
  for row in db.getAllRows(sql"""
      SELECT line_no, side, gl_account
        FROM ledger.posting_rule_line WHERE rule_id = ? ORDER BY line_no""", $ruleId):
    result.add PostingRuleLine(
      lineNo: parseInt(row[0]),
      side: (if row[1] == "DEBIT": nsDebit else: nsCredit),
      glAccount: row[2])

proc activeRules*(db: DbConn, eventType: string): seq[PostingRule] =
  ## Rule ACTIVE untuk tipe event ini; pemilihan final dilakukan `selectRule`.
  for row in db.getAllRows(sql"""
      SELECT rule_id, event_type, coalesce(product_code, ''), conditions::text, priority
        FROM ledger.posting_rule
       WHERE status = 'ACTIVE' AND event_type = ?
         AND (effective_from IS NULL OR effective_from <= current_date)
         AND (effective_to IS NULL OR effective_to >= current_date)
       ORDER BY priority, rule_id""", eventType):
    var rule = ruleOf(row)
    rule.lines = linesOf(db, rule.ruleId)
    result.add rule

proc insertRule*(db: DbConn, rule: PostingRule, createdBy: Id) =
  ## Dipakai seed/test. Validasi template dilakukan domain sebelum memanggil ini.
  db.exec(sql"""
    INSERT INTO ledger.posting_rule
      (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
    VALUES (?, ?, NULLIF(?, ''), ?::jsonb, ?, 'ACTIVE', ?, ?)""",
    $rule.ruleId, rule.eventType, rule.productCode,
    (if rule.conditions.isNil: "{}" else: $rule.conditions), $rule.priority,
    $createdBy, $createdBy)
  for l in rule.lines:
    db.exec(sql"""
      INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
      VALUES (?, ?, ?, ?)""", $rule.ruleId, $l.lineNo, $l.side, l.glAccount)
