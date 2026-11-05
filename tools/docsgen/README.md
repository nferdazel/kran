# docsgen

Generates the two inventory pages that must never be hand-written:

| Output | Source |
|---|---|
| `docs/PARAMETERS.md` | `modules/*/seeds/params.yaml`; cross-checked against `packs/base/generated/param_provenance.md` when present |
| `docs/SCHEMA.md` | `modules/*/migrations/*.sql` and `ops/migrations/contract-auto.txt` |

Python 3 standard library only. No network, no database, no writes outside `docs/`.
Output is deterministic: the same tree produces byte-identical files.

## Commands

```sh
python3 tools/docsgen/docsgen.py            # write both files
python3 tools/docsgen/docsgen.py params     # write docs/PARAMETERS.md
python3 tools/docsgen/docsgen.py schema     # write docs/SCHEMA.md
python3 tools/docsgen/docsgen.py --check    # regenerate in memory; exit 1 on drift
```

`--check` never writes. It prints a unified diff for each drifted file and exits non-zero, so
CI and `./task check` can treat drift as a failure.

## The markdown is never hand-edited

`docs/PARAMETERS.md` and `docs/SCHEMA.md` carry a `GENERATED FILE` header. A manual edit is a
defect: the next `--check` shows the drift and the next run overwrites it. Change the source
(seed YAML, migration SQL, or `contract-auto.txt`) and regenerate.

## What each page contains

`PARAMETERS.md` lists every key with class, scope, unit/type, seed pack, whether a value is
seeded, the provenance review marker, and the source file. Seeded values are deliberately not
printed; the generator fails if a seeded value looks like a credential.

`SCHEMA.md` lists every table sorted by schema then name, with the `COMMENT ON TABLE` purpose,
primary-key and foreign-key columns, PK/FK/unique/check counts, trigger names, and the newest
migration that touches the table. Unique counts include `CREATE UNIQUE INDEX`. Migrations that
never create a table appear in their own section instead of disappearing from the inventory.

## Failure behaviour

The generator stops with exit code 2 and names the file when a source cannot be parsed: an
unsupported YAML construct, a malformed `CREATE TABLE`/`ALTER TABLE`/`COMMENT`/`CREATE INDEX`
statement, a seed without `key`/`type`/`scopes`/`provenance.class`, a duplicate key, a secret-like
value, a contract id without a migration file, or a parameter catalogue whose keys disagree with
the seeds. It never guesses or silently skips a source.
