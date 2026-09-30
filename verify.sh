#!/bin/sh
# verify.sh — mgate against a repository whose every gate's answer is known.
#
#   MERE=/path/to/mere-checkout sh verify.sh [--poison]
#
# The fixture is a fake repo: a CI workflow with a gates job, and scripts that
# exit 0, 1, 2 and 3, print "skipping" and exit 0, and sleep past the timeout,
# plus a *_check.sh the workflow never names. What is checked:
#
# ⚠ The timeout is 15 s, not 2. It was 2, and on a loaded machine (a spec
#   sweep running; reproduced with ten busy loops on ten cores) starting a
#   process took 0.6 s, a gate is four or five of them, and gates that print
#   one line came back TIMEOUT. A bound in a fixture is a guess about the
#   machine's load: make it a generous one.
#
#   classes      each gate lands in its class (PASS FAIL CANNOT SKIP SKIP0
#                TIMEOUT), and a block step with two lines is one gate while a
#                step of two plain invocations is two
#   timeout      a gate that times out is killed with everything it started
#   unwired      the script the workflow does not name is run, and marked
#   red          --local turns CANNOT and SKIP0 from red to reported; FAIL and
#                TIMEOUT stay red either way (the exit status says so)
#   record       a second run compares with the first: a gate that went from
#                PASS to FAIL is listed under "went red"
#   floor        a workflow that lost a step is refused, not run
#   empty        a workflow with no gates is a failure, not a pass
#
# --poison builds two broken copies: a classifier that ignores the skip text
# (the SKIP0 check must catch it), and a timeout that kills only the top shell
# (the check for leftover children must).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "${MERE:-}" ] || { echo "usage: MERE=/path/to/mere-checkout sh verify.sh" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "verify: $M not found (dune build?)" >&2; exit 2; }
CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_repo() {  # $1 = dir, $2 = how many of the steps to keep (all | fewer | none)
  mkdir -p "$1/scripts" "$1/.github/workflows"
  printf '#!/bin/sh\necho "all good"\nexit 0\n' > "$1/scripts/pass_check.sh"
  printf '#!/bin/sh\necho "FAIL: two problems"\nexit 1\n' > "$1/scripts/fail_check.sh"
  printf '#!/bin/sh\necho "needs frobnicate -- cannot check" >&2\nexit 2\n' > "$1/scripts/cannot_check.sh"
  printf '#!/bin/sh\necho "optional, not configured here"\nexit 3\n' > "$1/scripts/optional_check.sh"
  printf '#!/bin/sh\necho "no qemu: skipping (this check is optional)"\nexit 0\n' > "$1/scripts/quiet_check.sh"
  printf '#!/bin/sh\nsleep 3001\n' > "$1/scripts/slow_check.sh"
  printf '#!/bin/sh\n[ "${1:-}" = "--poison" ] && { echo "poison caught"; exit 0; }\necho ok\n' > "$1/scripts/pair_check.sh"
  printf '#!/bin/sh\necho "nobody runs me"\nexit 1\n' > "$1/scripts/orphan_check.sh"
  printf '#!/bin/sh\n[ "${FLAVOR:-}" = "sweet" ] || { echo "FLAVOR not passed"; exit 1; }\necho ok\n' > "$1/scripts/env_check.sh"
  {
    echo "name: CI"
    echo "jobs:"
    echo "  build:"
    echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - run: echo building"
    echo "  gates:"
    echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - uses: actions/checkout@v5"
    echo "      - name: Install tools"
    echo "        run: |"
    echo "          sudo apt-get install -y frobnicate"
    if [ "$2" != none ]; then
      echo "      - name: pass"
      echo "        run: sh scripts/pass_check.sh"
      echo "      # a comment between steps"
      echo "      - name: \"fail (a gate that is red)\""
      echo "        if: \${{ !cancelled() }}"
      echo "        run: opam exec -- sh scripts/fail_check.sh"
      echo "      - name: cannot"
      echo "        run: sh scripts/cannot_check.sh"
      echo "      - name: optional"
      echo "        run: sh scripts/optional_check.sh"
      echo "      - name: quiet"
      echo "        run: sh scripts/quiet_check.sh"
      echo "      - name: slow"
      echo "        run: sh scripts/slow_check.sh"
      echo "      - name: env"
      echo "        env:"
      echo "          FLAVOR: sweet"
      echo "          TOKEN: \${{ secrets.X }}"
      echo "        run: sh scripts/env_check.sh"
      if [ "$2" = all ]; then
        echo "      - name: pair (two invocations, two gates)"
        echo "        run: |"
        echo "          sh scripts/pair_check.sh"
        echo "          sh scripts/pair_check.sh --poison"
        echo "      - name: block (one script, one gate)"
        echo "        run: |"
        echo "          # a comment line"
        echo "          X=1"
        echo "          sh scripts/pair_check.sh"
      fi
    fi
    echo "  later:"
    echo "    steps:"
    echo "      - run: sh scripts/unrelated.sh"
  } > "$1/.github/workflows/ci.yml"
}

build() {  # $1 = source dir, $2 = binary
  "$M" -c "$1/mgate.mere" > "$TMP/mgate.c" 2>"$TMP/err" || { echo "FAIL verify: mere -c"; cat "$TMP/err"; return 1; }
  "$CC" -O2 -w "$TMP/mgate.c" -o "$2" || { echo "FAIL verify: cc"; return 1; }
}

run_checks() {  # $1 = mgate binary
  B="$1"; bad=0
  rm -rf "$TMP/repo" "$TMP/home"; make_repo "$TMP/repo" all
  export HOME="$TMP/home"
  "$B" ci "$TMP/repo" --timeout 15 --jobs 4 > "$TMP/out1" 2>/dev/null; rc1=$?
  want_class() {  # $1 = status, $2 = gate name
    grep -q "^   $1 *$2 " "$TMP/out1" || { echo "FAIL class: $2 is not $1"; bad=$((bad + 1)); }
  }
  want_class FAIL "fail_check.sh"
  want_class CANNOT "cannot_check.sh"
  want_class SKIP0 "quiet_check.sh"
  want_class TIMEOUT "slow_check.sh"
  want_class SKIP "optional_check.sh"
  grep -q "orphan_check.sh *\[unwired\]" "$TMP/out1" || { echo "FAIL unwired: orphan_check.sh not run and marked"; bad=$((bad + 1)); }
  grep -q "env_check.sh" "$TMP/out1" && { echo "FAIL env: a step's env did not reach its gate"; bad=$((bad + 1)); }
  line="$(grep '^mgate: ' "$TMP/out1")"
  case "$line" in
    "mgate: 11 gates -- 5 PASS, 2 FAIL, 1 TIMEOUT, 1 CANNOT, 1 SKIP0, 1 SKIP"*) ;;
    *) echo "FAIL counts: $line"; bad=$((bad + 1)) ;;
  esac
  [ $rc1 -eq 1 ] || { echo "FAIL red: exit $rc1 with reds present"; bad=$((bad + 1)); }
  grep -q "unrelated" "$TMP/out1" && { echo "FAIL scope: a script from another job was run"; bad=$((bad + 1)); }
  # a timeout kills the gate's whole tree, not only its shell
  pgrep -f "sleep 3001" > /dev/null && { echo "FAIL timeout: the timed-out gate's children are still running"; pkill -f "sleep 3001"; bad=$((bad + 1)); }

  # --local: CANNOT and SKIP0 are reported, not red; FAIL and TIMEOUT stay red
  "$B" ci "$TMP/repo" --timeout 15 --local --record "$TMP/local.json" > "$TMP/out2" 2>/dev/null
  sed -n '/^== red/,/^== /p' "$TMP/out2" | grep -q "cannot_check\|quiet_check" \
    && { echo "FAIL --local: CANNOT/SKIP0 still listed as red"; bad=$((bad + 1)); }
  sed -n '/^== red/,/^== /p' "$TMP/out2" | grep -q "slow_check" \
    || { echo "FAIL --local: TIMEOUT is no longer red"; bad=$((bad + 1)); }

  # the record: pass_check goes red, and the second run says so first
  printf '#!/bin/sh\necho "broken now"\nexit 1\n' > "$TMP/repo/scripts/pass_check.sh"
  "$B" ci "$TMP/repo" --timeout 15 > "$TMP/out3" 2>/dev/null
  sed -n '/^== went red/,/^== /p' "$TMP/out3" | grep -q "PASS -> FAIL *pass_check.sh" \
    || { echo "FAIL record: a PASS that became FAIL is not under 'went red'"; bad=$((bad + 1)); }

  # the floor: two steps gone is refused
  make_repo "$TMP/repo" fewer
  "$B" ci "$TMP/repo" --timeout 15 > "$TMP/out4" 2>/dev/null; rc4=$?
  { [ $rc4 -eq 1 ] && grep -q "the last run had" "$TMP/out4"; } \
    || { echo "FAIL floor: a shorter list ran (exit $rc4)"; bad=$((bad + 1)); }

  # empty: a gates job with nothing in it
  rm -rf "$TMP/repo"; make_repo "$TMP/repo" none; rm "$TMP/repo/scripts/"*_check.sh
  "$B" ci "$TMP/repo" --record "$TMP/empty.json" > "$TMP/out5" 2>/dev/null; rc5=$?
  { [ $rc5 -eq 1 ] && grep -q "an empty list is not a pass" "$TMP/out5"; } \
    || { echo "FAIL empty: no gates was exit $rc5"; bad=$((bad + 1)); }

  [ $bad -eq 0 ] || { echo "verify: $bad problem(s)"; return 1; }
  echo "ok | mgate: 6 classes, unwired, env, --local, the record, the floor, the empty list"
}

build "$DIR" "$TMP/mgate" || exit 1

# a poison: $1 = what, $2 = the exact fragment, $3 = its replacement, $4 = the
# FAIL line that must appear
poison() {
  rm -rf "$TMP/p"; mkdir -p "$TMP/p"; cp "$DIR/mgate.mere" "$TMP/p/"
  python3 - "$TMP/p/mgate.mere" "$2" "$3" <<'PY' || { echo "FAIL poison ($1): fragment not found"; return 1; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  build "$TMP/p" "$TMP/pmgate" || return 1
  if run_checks "$TMP/pmgate" > "$TMP/poison.log" 2>&1; then echo "FAIL poison ($1): passed"; return 1; fi
  grep -q "^$4" "$TMP/poison.log" || { echo "FAIL poison ($1): CAUGHT FOR THE WRONG REASON"; head -5 "$TMP/poison.log"; return 1; }
  echo "ok | poison caught ($1)"
}

if [ "${1:-}" = "--poison" ]; then
  poison "a skip that exits 0 read as a pass" \
    'if str_contains (to_lower last) "skip" then "SKIP0" else "PASS"' '"PASS"' \
    "FAIL class: quiet_check.sh is not SKIP0" || exit 1
  poison "a timeout that kills only the top shell" \
    'kill \"KILL\", -$pid;' 'kill \"KILL\", $pid;' \
    "FAIL timeout: the timed-out gate's children" || exit 1
  echo "verify --poison: ok"; exit 0
fi

run_checks "$TMP/mgate" || exit 1
echo "verify: ok"
