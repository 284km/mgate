# mgate

A gate runner written in [Mere](https://github.com/merelang/mere): it runs every
check a repository has, classifies each result, and says what changed since
the last run.

```
mgate ci <repo> [options]                  every `run:` of the CI workflow's gates
                                           job, plus every scripts/*_check.sh the
                                           workflow does not name
mgate verify <mere> <repo>... [options]    each repo's declared checks: the `run`
                                           list under [test] in mere.toml, or its
                                           verify.sh

  --jobs N  --timeout S  --local  --no-poison  --only WORD  --record PATH
  --accept-fewer  --list
```

## Why

A gate that exits 0 when it could not run is a gate that cannot fail. In the
Mere repository, gates printed "skipping" and exited 0 when a tool was missing,
and a gate that was in no workflow could be red for weeks. So mgate:

- **derives the list** instead of keeping one: the workflow's steps (one gate
  per plain invocation, one per multi-line block) and every `*_check.sh` the
  workflow does not name, marked *unwired*. An empty list is a failure; a list
  shorter than the last run's is a failure unless `--accept-fewer`
- **classes exit statuses**: 0 PASS, 1 FAIL, 2 CANNOT (it could not answer),
  3 SKIP (declared optional), 201 TIMEOUT. A 0 whose last line says `SKIP`,
  `skipping` or `skip-ok` is **SKIP0**, an undeclared skip, and is red unless
  `--local`. A pass that counts what it left out ("(13 skipped)") is a pass
- **compares with the last run**, group by group (a group is a script's name
  up to its first underscore), and prints what went from green to red first.
  The record is a JSON list of records, `~/.cache/mgate/<name>.json`
- **kills a timed-out gate's whole process group**, so a server a gate started
  does not hold its port for the next one

Leading assignments and step `env:` values that name the CI machine
(`$RUNNER_TEMP/...`, a path that does not exist here) are left out, so a gate
says what it could not check instead of failing on a path nobody meant.
`mgate verify` passes the compiler as `MERE` and `MERE_BIN`.

## What it has found

Run over the Mere repository's 168 gates, the first time: a gate that breaks
when run beside its own `--poison` (a fixed scratch file name), three passes
misread as skips, and two gates handed CI-only paths. Run over 21 downstream
repositories: `MERE` meant the compiler in 12 of them and a checkout in 9, and
four were red on the released compiler without anybody knowing.

## Checking it

```
MERE=/path/to/mere.exe sh verify.sh            # a fixture repo whose every answer is known
MERE=/path/to/mere.exe sh verify.sh --poison   # the checks can fail
```

C backend only (it uses `spawn`, channels and `run`).
