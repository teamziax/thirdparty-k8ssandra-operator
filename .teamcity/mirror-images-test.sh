#!/usr/bin/env bash
# Tests mirror-images.sh against two in-memory registries (crane registry serve) and a stand-in for Quay's API: what
# it copies, what it leaves alone, re-runs of a commit, the sha- tags it adds and marks immutable, and failures. It
# needs curl, python3, sha256sum and GitHub, for crane, and touches nothing outside a scratch directory, which --keep
# leaves behind. Usage: bash .teamcity/mirror-images-test.sh [--keep]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FRAGMENT="$HERE/mirror-images.sh"
T=$(mktemp -d)
KEEP=${1:-}
SRC=127.0.0.1:55101
DST=127.0.0.1:55102
API=127.0.0.1:55103
pids=()
finish() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  if [ "$KEEP" = --keep ]; then echo "Scratch directory: $T"; else rm -rf "$T"; fi
}
trap finish EXIT
fails=0
check() { # description, then a command that must succeed
  local what=$1; shift
  if "$@"; then echo "  ok   $what"; else echo "  FAIL $what"; fails=$((fails + 1)); fi
}

# crane for building the test images and serving the registries, pinned as the fragment pins it.
mkdir -p "$T/bin"
curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz" -o "$T/ggcr.tar.gz"
echo "0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0  $T/ggcr.tar.gz" | sha256sum -c --quiet
tar -xzf "$T/ggcr.tar.gz" -C "$T/bin" crane
CRANE="$T/bin/crane"
for r in "$SRC" "$DST"; do
  "$CRANE" registry serve --address "$r" > "$T/registry-${r##*:}.log" 2>&1 &
  pids+=($!)
done

# A stand-in for Quay's tag API, enough for the fragment: PUT .../tag/<tag> {"immutable": true} with the test's Bearer
# token, and GET .../tag/?specificTag=<tag> reading it back. $T/api-mode says how it behaves: ok, forbidden (403), or
# off (Quay with FEATURE_IMMUTABLE_TAGS off: it answers 201 and changes nothing). $T/api-calls logs every call.
echo ok > "$T/api-mode"
python3 - "$API" "$T" <<'PY' > "$T/api.log" 2>&1 &
import http.server
import json
import os
import sys
import urllib.parse

address, scratch = sys.argv[1], sys.argv[2]
state = {}


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_call(self, method):
        url = urllib.parse.urlsplit(self.path)
        mode = open(os.path.join(scratch, "api-mode")).read().strip()
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) if method == "PUT" else b""
        with open(os.path.join(scratch, "api-calls"), "a") as log:
            log.write("{} {} {} {}\n".format(method, url.path + ("?" + url.query if url.query else ""),
                                             self.headers.get("Authorization") == "Bearer test-token", body.decode()))
        if self.headers.get("Authorization") != "Bearer test-token":
            return self.reply(401, {"error": "unauthorized"})
        repo, _, tag = url.path.partition("/tag/")
        if method == "PUT":
            if mode == "forbidden":
                return self.reply(403, {"error": "forbidden"})
            if mode == "ok" and json.loads(body).get("immutable") is True:
                state[(repo, tag)] = True
            return self.reply(201, "Updated")
        wanted = urllib.parse.parse_qs(url.query).get("specificTag", [""])[0]
        return self.reply(200, {"tags": [{"name": wanted, "immutable": state.get((repo, wanted), False)}]})

    def do_PUT(self):
        self.handle_call("PUT")

    def do_GET(self):
        self.handle_call("GET")


host, port = address.split(":")
http.server.HTTPServer((host, int(port)), Api).serve_forever()
PY
pids+=($!)
sleep 1

# An image whose content, and so digest, is set by $2; prints its digest.
image() {
  echo "$2" > "$T/content"
  "$CRANE" append -f <(tar -cf - -C "$T" content) -t "$1" >/dev/null 2>&1
  "$CRANE" digest "$1"
}

# A ccbuild record (build/images/<image>.json, pretty-printed) or a publish-image.sh one (image.json). A ccbuild
# record's ref and revision are $REF and $REV, refs/heads/production and forty zeros unless set.
ccbuild_record() { # dir, image, digest, pushed, tags...
  local dir=$1 img=$2 digest=$3 pushed=$4; shift 4
  mkdir -p "$dir/build/images/$(dirname "$img")"
  python3 - "$dir/build/images/$img.json" "$img" "$digest" "$pushed" "${REF:-refs/heads/production}" \
    "${REV:-0000000000000000000000000000000000000000}" "$@" <<'PY'
import json, sys
out, image, digest, pushed, ref, revision, *tags = sys.argv[1:]
json.dump({"image": image, "tags": tags, "digest": f"{image}@{digest}" if digest else "",
           "pushed": pushed == "true", "ref": ref, "revision": revision},
          open(out, "w"), indent=4)
PY
}
publish_record() { # dir, image, digest, tags...
  local dir=$1 img=$2 digest=$3; shift 3
  python3 - "$dir/image.json" "$img" "$digest" "$@" <<'PY'
import json, sys
out, image, digest, *tags = sys.argv[1:]
json.dump({"image": image, "tags": tags, "digest": f"{image}@{digest}", "pushed": True,
           "ref": "refs/heads/main", "revision": "0" * 40}, open(out, "w"), indent=2)
PY
}

# Runs the fragment in $1 as a deploy step would, after set -euo pipefail, with the rest of the arguments as
# environment. Its output goes to $1/out and its exit status to $1/rc.
run() {
  local dir=$1; shift
  # shellcheck disable=SC2016 # the inner bash expands $0
  (cd "$dir" && env HOME="$T/home" DOCKER_CONFIG="$T/docker" ZIAX_MIRROR_FROM="$SRC" "$@" \
    bash -c 'set -euo pipefail; source "$0"' "$FRAGMENT") > "$dir/out" 2>&1 && echo 0 > "$dir/rc" || echo $? > "$dir/rc"
}
rc() { [ "$(cat "$1/rc")" = "$2" ]; }
says() { grep -q -F -- "$2" "$1/out"; }
digest_of() { "$CRANE" digest "$1" 2>/dev/null; }
pushes() { grep -c -E '^(copy|tag) ' "$T/crane-calls" 2>/dev/null || true; }
mkdir -p "$T/docker" "$T/home"

echo "0. Nothing happens without ZIAX_MIRROR"
d=$T/s0; mkdir -p "$d"; D1=$(image "$SRC/games/skywars:production" one)
ccbuild_record "$d" "$SRC/games/skywars" "$D1" true production
run "$d"
check "exits 0" rc "$d" 0
check "prints nothing" test ! -s "$d/out"
check "installs no crane" test ! -e "$T/home/.tc-tools/crane"

echo "1. A pushed image is copied by digest, and crane installed"
d=$T/s1; mkdir -p "$d"; ccbuild_record "$d" "$SRC/games/skywars" "$D1" true production
run "$d" ZIAX_MIRROR="$DST/cubecraft"
check "exits 0" rc "$d" 0
check "crane is installed and pinned" bash -c "'$T/home/.tc-tools/crane' version | grep -qx 0.22.1"
check "cubecraft/games/skywars:production has the same digest" test "$(digest_of "$DST/cubecraft/games/skywars:production")" = "$D1"
check "counts one copy" says "$d" "1 tag(s) copied, 0 already there"

# From here on crane is a wrapper that logs each call, so the tests can count pushes.
mv "$T/home/.tc-tools/crane" "$T/home/.tc-tools/crane.real"
cat > "$T/home/.tc-tools/crane" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/crane-calls"
exec "$T/home/.tc-tools/crane.real" "\$@"
EOF
chmod +x "$T/home/.tc-tools/crane"

echo "2. The same image again: looked up, not pushed"
: > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/cubecraft"
check "exits 0" rc "$d" 0
check "pushes nothing" test "$(pushes)" = 0
check "says it is already there" says "$d" "cubecraft/games/skywars:production is already $D1"

echo "3. A new build moves production"
d=$T/s3; mkdir -p "$d"; D2=$(image "$SRC/games/skywars:production" two)
ccbuild_record "$d" "$SRC/games/skywars" "$D2" true production
: > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/cubecraft"
check "production is the new digest" test "$(digest_of "$DST/cubecraft/games/skywars:production")" = "$D2"
check "one push" test "$(pushes)" = 1

echo "4. publish-image.sh's record: the sha- tag and production"
d=$T/s4; mkdir -p "$d"; D3=$(image "$SRC/services/paseo-hub:sha-aaaaaaaaaaaa" three)
publish_record "$d" "$SRC/services/paseo-hub" "$D3" sha-aaaaaaaaaaaa production
: > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/ziax"
check "exits 0" rc "$d" 0
check "the sha- tag is copied" test "$(digest_of "$DST/ziax/services/paseo-hub:sha-aaaaaaaaaaaa")" = "$D3"
check "production is copied" test "$(digest_of "$DST/ziax/services/paseo-hub:production")" = "$D3"
check "the sha- tag goes first" bash -c "head -1 <(grep -E '^copy ' '$T/crane-calls') | grep -q ':sha-aaaaaaaaaaaa\$'"

echo "5. A re-run of that commit: the sha- tag is not pushed over, and production points at the kept build"
D9=$(image "$SRC/services/paseo-hub:other" nine)
"$CRANE" copy "$SRC/services/paseo-hub@$D9" "$DST/ziax/services/paseo-hub:production" >/dev/null 2>&1
d=$T/s5; mkdir -p "$d"; D4=$(image "$SRC/services/paseo-hub:sha-aaaaaaaaaaaa" four)
publish_record "$d" "$SRC/services/paseo-hub" "$D4" sha-aaaaaaaaaaaa production
: > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/ziax"
check "exits 0" rc "$d" 0
check "the sha- tag keeps the first build" test "$(digest_of "$DST/ziax/services/paseo-hub:sha-aaaaaaaaaaaa")" = "$D3"
check "production points at the first build" test "$(digest_of "$DST/ziax/services/paseo-hub:production")" = "$D3"
check "this build's image is never copied" bash -c "! grep -q '$D4' '$T/crane-calls'"
check "says it kept the earlier build" says "$d" "kept from an earlier build"
check "no failure" says "$d" "1 kept from an earlier build, 0 failed"

echo "6. Not pushed, no digest, or from another registry: nothing copied"
d=$T/s6; mkdir -p "$d"
ccbuild_record "$d" "$SRC/web/forums" "" false production
ccbuild_record "$d" "quay.io/ziax/java" "$D1" true 21
: > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/cubecraft"
check "exits 0" rc "$d" 0
check "pushes nothing" test "$(pushes)" = 0
check "skips the dry run" says "$d" "was not pushed"
check "skips quay.io" says "$d" "is on quay.io, which is not copied"

echo "7. An unreachable mirror is a warning, unless the mirror is required"
d=$T/s7; mkdir -p "$d"; ccbuild_record "$d" "$SRC/games/skywars" "$D2" true production
run "$d" ZIAX_MIRROR="127.0.0.1:55199/cubecraft"
check "exits 0" rc "$d" 0
check "warns" says "$d" "status='WARNING'"
check "tags the build" says "$d" "##teamcity[addBuildTag 'quay-mirror-failed']"
run "$d" ZIAX_MIRROR="127.0.0.1:55199/cubecraft" ZIAX_MIRROR_REQUIRED=true
check "required: exits 1" rc "$d" 1
check "required: a build problem" says "$d" "##teamcity[buildProblem"

echo "8. After a deploy script's EXIT trap, a required failure keeps the trap and its status"
d=$T/s8; mkdir -p "$d"; ccbuild_record "$d" "$SRC/games/skywars" "$D2" true production
# shellcheck disable=SC2016 # the inner bash expands $0
(cd "$d" && env HOME="$T/home" DOCKER_CONFIG="$T/docker" ZIAX_MIRROR_FROM="$SRC" ZIAX_MIRROR="127.0.0.1:55199/cubecraft" \
  ZIAX_MIRROR_REQUIRED=true bash -c 'set -euo pipefail; trap "echo cleanup ran" EXIT; source "$0"' "$FRAGMENT") \
  > "$d/out" 2>&1 && echo 0 > "$d/rc" || echo $? > "$d/rc"
check "exits 1" rc "$d" 1
check "the trap still runs" says "$d" "cleanup ran"

# The calls the stand-in API had since the last reset, and what they asked.
api_calls() { grep -c . "$T/api-calls" 2>/dev/null || true; }
api_reset() { : > "$T/api-calls"; echo "${1:-ok}" > "$T/api-mode"; }
put_for() { grep -q -E "^PUT /api/v1/repository/$1/tag/$2 True \\{\"immutable\": true\\}\$" "$T/api-calls"; }
SHA_ON=(ZIAX_MIRROR_SHA_TAGS=true ZIAX_MIRROR_API="http://$API")
REVISION=abcdef0123456789abcdef0123456789abcdef01

echo "9. A production record with no sha- tag, the switch on: sha-<revision> in the mirror only, marked immutable"
d=$T/s9; mkdir -p "$d"; D5=$(image "$SRC/cubecraft-legacy/steve:production" five)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/steve" "$D5" true production
api_reset; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "exits 0" rc "$d" 0
check "the mirror has sha-abcdef012345 at the digest" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/steve:sha-abcdef012345")" = "$D5"
check "and production" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/steve:production")" = "$D5"
check "the first registry has no sha- tag" bash -c "! '$CRANE' digest '$SRC/cubecraft-legacy/steve:sha-abcdef012345' 2>/dev/null"
check "one PUT marks it immutable, with the token" put_for cubecraft/cubecraft-legacy/steve sha-abcdef012345
check "and only it: production is left mutable" bash -c "[ \"\$(grep -c '^PUT ' '$T/api-calls')\" = 1 ]"
check "says it marked it" says "$d" "marked $DST/cubecraft/cubecraft-legacy/steve:sha-abcdef012345 immutable"
check "counts it" says "$d" "1 sha- tag(s) marked immutable, 0 left mutable"
check "the token is never printed" bash -c "! grep -q test-token '$d/out'"

echo "10. The same record again: nothing pushed, nothing marked again"
api_reset; : > "$T/crane-calls"; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "exits 0" rc "$d" 0
check "pushes nothing" test "$(pushes)" = 0
check "calls no API" test "$(api_calls)" = 0

echo "11. A rebuild of that commit: the sha- tag keeps the first build, and production follows it"
d=$T/s11; mkdir -p "$d"; D6=$(image "$SRC/cubecraft-legacy/steve:production" six)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/steve" "$D6" true production
api_reset; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "exits 0" rc "$d" 0
check "sha-abcdef012345 is still the first build" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/steve:sha-abcdef012345")" = "$D5"
check "production points at it" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/steve:production")" = "$D5"
check "calls no API" test "$(api_calls)" = 0

echo "12. master's record, the switch on: no sha- tag, because master builds another image from the same commit"
d=$T/s12; mkdir -p "$d"; D7=$(image "$SRC/cubecraft-legacy/nick:dev" seven)
REF=refs/heads/master REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/nick" "$D7" true dev
api_reset; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "exits 0" rc "$d" 0
check "dev is copied" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/nick:dev")" = "$D7"
check "no sha- tag" bash -c "! '$CRANE' digest '$DST/cubecraft/cubecraft-legacy/nick:sha-abcdef012345' 2>/dev/null"
check "calls no API" test "$(api_calls)" = 0

echo "13. The switch off, as every deploy has it until it is turned on: no sha- tag"
d=$T/s13; mkdir -p "$d"; D8=$(image "$SRC/cubecraft-legacy/cube-bot:production" eight)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/cube-bot" "$D8" true production
api_reset; run "$d" ZIAX_MIRROR="$DST/cubecraft" ZIAX_MIRROR_API="http://$API" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "production is copied" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/cube-bot:production")" = "$D8"
check "no sha- tag" bash -c "! '$CRANE' digest '$DST/cubecraft/cubecraft-legacy/cube-bot:sha-abcdef012345' 2>/dev/null"
check "calls no API" test "$(api_calls)" = 0

echo "14. No token: the sha- tag is copied, left mutable, and the build warns and is tagged"
d=$T/s14; mkdir -p "$d"; D10=$(image "$SRC/cubecraft-legacy/rank-notifier:production" ten)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/rank-notifier" "$D10" true production
api_reset; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}"
check "exits 0" rc "$d" 0
check "the sha- tag is copied" test "$(digest_of "$DST/cubecraft/cubecraft-legacy/rank-notifier:sha-abcdef012345")" = "$D10"
check "calls no API" test "$(api_calls)" = 0
check "warns" says "$d" "is not marked immutable (no ZIAX_MIRROR_QUAY_TOKEN)"
check "tags the build" says "$d" "##teamcity[addBuildTag 'quay-sha-mutable']"
check "no copy failed" says "$d" "0 failed; 0 sha- tag(s) marked immutable, 1 left mutable"

echo "15. Quay refuses the change, or takes it and ignores it: a warning, never a failed build"
d=$T/s15; mkdir -p "$d"; D11=$(image "$SRC/cubecraft-legacy/sentinel-service:production" eleven)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/sentinel-service" "$D11" true production
api_reset forbidden; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "403: exits 0" rc "$d" 0
check "403: says why" says "$d" "could not mark $DST/cubecraft/cubecraft-legacy/sentinel-service:sha-abcdef012345 immutable: HTTP 403"
d=$T/s15b; mkdir -p "$d"; D12=$(image "$SRC/cubecraft-legacy/steve-two:production" twelve)
REV=$REVISION ccbuild_record "$d" "$SRC/cubecraft-legacy/steve-two" "$D12" true production
api_reset off; run "$d" ZIAX_MIRROR="$DST/cubecraft" "${SHA_ON[@]}" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "feature off: exits 0" rc "$d" 0
check "feature off: noticed on read-back" says "$d" "reads back mutable"
check "feature off: tags the build" says "$d" "##teamcity[addBuildTag 'quay-sha-mutable']"

echo "16. publish-image.sh's own sha- tag is marked too, switch or no switch"
d=$T/s16; mkdir -p "$d"; D13=$(image "$SRC/services/bluemap-cli:sha-bbbbbbbbbbbb" thirteen)
publish_record "$d" "$SRC/services/bluemap-cli" "$D13" sha-bbbbbbbbbbbb production
api_reset; run "$d" ZIAX_MIRROR="$DST/ziax" ZIAX_MIRROR_API="http://$API" ZIAX_MIRROR_QUAY_TOKEN=test-token
check "exits 0" rc "$d" 0
check "marked" put_for ziax/services/bluemap-cli sha-bbbbbbbbbbbb
check "no other tag added" bash -c "[ \"\$(grep -c '^PUT ' '$T/api-calls')\" = 1 ]"

echo "17. The fragment holds no percent sign"
check "none" bash -c "! grep -q '%' '$FRAGMENT'"

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "All checks passed"
