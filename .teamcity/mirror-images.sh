# Fragment, after the step that publishes images: copies every image the build pushed to a second registry, by
# digest, so both registries hold the identical image. It is how the OVH registry and Quay (cr.ziax.ltd) run side by
# side while images move from one to the other. Every repository on our TeamCity carries an identical copy, like
# Ziax.kt and publish-image.sh.
#
# It reads the records the publish left, build/images/**/*.json from ccbuild or image.json from publish-image.sh, and
# copies each image that was pushed with a digest: <host>/<path> goes to $ZIAX_MIRROR/<path>.
#
# sha- tags in the mirror. A sha-<12 hex> tag names one build of one commit; hydration pins images by them, because a
# digest no tag holds is deleted a day after its tag moves. publish-image.sh's records carry one; ccbuild's carry only
# the moving tag. With ZIAX_MIRROR_SHA_TAGS on, a record built from the trunk ref (ZIAX_MIRROR_TRUNK_REF) that has no
# sha- tag gets sha-<first 12 hex of its revision> in the mirror only. Only the trunk: master builds a different image
# from the same commit (dev augments, PROD=false), so a sha- tag there would name two images. Each sha- tag the mirror
# creates, from a record or added, is then marked immutable through Quay's API, so it can never be moved or deleted
# except by the cleanup job. Quay's API takes an OAuth token, never a robot's login, so that needs
# ZIAX_MIRROR_QUAY_TOKEN; without one the tag is left mutable, with a warning.
#
# Each tag is looked up in the mirror before anything is pushed, and pushed only when the mirror doesn't have it:
#   - A tag that already names this digest is left as it is.
#   - A sha-<12 hex> tag names one build of one commit and is immutable in Quay, so it is never pushed over. A re-run
#     of that commit builds another digest; the mirror keeps the first build's image, and the record's other tags are
#     pointed at that image instead, as a re-run moves them in the first registry.
#   - Any other tag that names another image, such as production a deploy ago, is moved to this build's image.
#
# Inputs:
#   ZIAX_MIRROR           registry and organization to copy to, e.g. cr.ziax.ltd/cubecraft; unset, nothing happens
#   ZIAX_MIRROR_FROM      the registry hosts whose images are copied, space-separated; images on any other are not
#   ZIAX_MIRROR_REQUIRED  "true" fails the build when a copy fails. Otherwise a failure is a warning and tags the build
#                         quay-mirror-failed: the publish to the first registry stands either way.
#   ZIAX_MIRROR_SHA_TAGS  "true" adds sha-<revision> to trunk records that have no sha- tag, as above
#   ZIAX_MIRROR_TRUNK_REF the ref whose records may get one; refs/heads/production unless set
#   ZIAX_MIRROR_QUAY_TOKEN an OAuth token for Quay's API, scope repo:write on the organization, issued to a regular
#                         Quay user (robots cannot call the API): marks the sha- tags the mirror creates immutable
#   ZIAX_MIRROR_API       Quay's API, https://<the mirror's host> unless set (the test points it at a stand-in)
#   DOCKER_CONFIG         where the build is logged in to both registries
#
# crane is pinned by version and checksum, as yq-tools.sh pins yq, in the same tools directory. The fragment holds no
# percent sign: TeamCity reads a pair of them in a step script as a parameter reference.
if [ -n "${ZIAX_MIRROR:-}" ]; then
  mirror_copied=0
  mirror_same=0
  mirror_kept=0
  mirror_failed=0
  mirror_marked=0
  mirror_unmarked=0
  mirror_err=$(mktemp)
  mirror_crane="$HOME/.tc-tools/crane"

  # A TeamCity service message value: its quote, bar and brackets escaped, one line.
  mirror_tc() {
    echo "$1" | head -1 | sed -e 's/|/||/g' -e "s/'/|'/g" -e 's/\[/|[/g' -e 's/\]/|]/g'
  }

  mirror_fail() {
    mirror_failed=$((mirror_failed + 1))
    echo "Quay mirror: $1"
    echo "##teamcity[message text='$(mirror_tc "Quay mirror: $1")' status='WARNING']"
  }

  mirror_install_crane() {
    local version=0.22.1
    # The SHA-256 of go-containerregistry_Linux_x86_64.tar.gz in the release's checksums.txt.
    local sum=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
    local dl
    if "$mirror_crane" version 2>/dev/null | grep -qx "$version"; then
      return 0
    fi
    mkdir -p "$HOME/.tc-tools" || return 1
    # Downloaded inside the tools directory and renamed into place, as yq-tools.sh does: the agents share this home,
    # and a rename within one filesystem is atomic, so another agent never runs a half-copied binary.
    dl=$(mktemp -d "$HOME/.tc-tools/.download.XXXXXX") || return 1
    curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v$version/go-containerregistry_Linux_x86_64.tar.gz" \
      -o "$dl/ggcr.tar.gz" || return 1
    echo "$sum  $dl/ggcr.tar.gz" | sha256sum -c --quiet || return 1
    tar -xzf "$dl/ggcr.tar.gz" -C "$dl" crane || return 1
    mv "$dl/crane" "$mirror_crane" || return 1
    rm -rf "$dl"
  }

  # Six lines: whether the image was pushed, the image, its digest (sha256:<hex>), its tags (space-separated), the ref
  # it was built from and its revision.
  mirror_read() {
    python3 - "$1" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1]))
print("true" if record.get("pushed") is True else "false")
print(record.get("image") or "")
print((record.get("digest") or "").rpartition("@")[2])
print(" ".join(record.get("tags") or []))
print(record.get("ref") or "")
print(record.get("revision") or "")
PY
  }

  # Marks a sha- tag the mirror has just created immutable, through Quay's API, and reads it back: Quay accepts the
  # change and ignores it while its immutable tags feature is off. The token comes from the environment and is never
  # printed.
  mirror_mark() {
    local dest=$1 tag=$2 out
    if [ -z "${ZIAX_MIRROR_QUAY_TOKEN:-}" ]; then
      mirror_unmarked=$((mirror_unmarked + 1))
      echo "Quay mirror: $dest:$tag is not marked immutable: ZIAX_MIRROR_QUAY_TOKEN is not set, and robots cannot" \
        "call Quay's API"
      echo "##teamcity[message text='$(mirror_tc "Quay mirror: $dest:$tag is not marked immutable (no ZIAX_MIRROR_QUAY_TOKEN)")' status='WARNING']"
      return 0
    fi
    if out=$(MIRROR_DEST="$dest" MIRROR_TAG="$tag" python3 - 2>&1 <<'PY'
import json
import os
import urllib.error
import urllib.parse
import urllib.request

dest, tag = os.environ["MIRROR_DEST"], os.environ["MIRROR_TAG"]
host, _, rest = dest.partition("/")
api = os.environ.get("ZIAX_MIRROR_API") or "https://" + host
base = "{}/api/v1/repository/{}/tag/".format(api.rstrip("/"), rest)
auth = {"Authorization": "Bearer " + os.environ["ZIAX_MIRROR_QUAY_TOKEN"]}


def call(method, url, body=None):
    headers = dict(auth, Accept="application/json")
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


status, body = call("PUT", base + urllib.parse.quote(tag), json.dumps({"immutable": True}).encode())
if status // 100 != 2:
    raise SystemExit("HTTP {}: {}".format(status, body[:200].decode(errors="replace")))
status, body = call("GET", base + "?" + urllib.parse.urlencode({"specificTag": tag, "onlyActiveTags": "true"}))
tags = json.loads(body).get("tags", []) if status == 200 else []
if not tags or tags[0].get("immutable") is not True:
    raise SystemExit("Quay took the change, but the tag reads back mutable (HTTP {}): is FEATURE_IMMUTABLE_TAGS on?"
                     .format(status))
PY
    ); then
      mirror_marked=$((mirror_marked + 1))
      echo "Quay mirror: marked $dest:$tag immutable"
    else
      mirror_unmarked=$((mirror_unmarked + 1))
      echo "Quay mirror: could not mark $dest:$tag immutable: $(echo "$out" | tail -1)"
      echo "##teamcity[message text='$(mirror_tc "Quay mirror: could not mark $dest:$tag immutable: $(echo "$out" | tail -1)")' status='WARNING']"
    fi
  }

  # What a tag names in the mirror, on standard output. Returns 0 if found, 1 if the mirror doesn't have it, 2 if it
  # could not be looked up. Quay answers 401 for a repository the robot cannot see, which is also how a repository
  # that doesn't exist yet looks to it: the copy then creates it, or fails and says why.
  mirror_lookup() {
    if "$mirror_crane" digest "$1" 2>"$mirror_err"; then
      return 0
    fi
    if grep -q -E 'MANIFEST_UNKNOWN|NAME_UNKNOWN|UNAUTHORIZED|401 Unauthorized' "$mirror_err"; then
      return 1
    fi
    return 2
  }

  mirror_record() {
    local file=$1 pushed image digest tags ref revision sha host path dest tag current target status
    if ! { read -r pushed && read -r image && read -r digest && read -r tags && read -r ref && read -r revision; } \
      < <(mirror_read "$file"); then
      mirror_fail "could not read $file"
      return 0
    fi
    if [ "$pushed" != true ] || [ -z "$digest" ]; then
      echo "Quay mirror: $image was not pushed, so there is nothing to copy"
      return 0
    fi
    host=$(echo "$image" | cut -d/ -f1)
    path=$(echo "$image" | cut -d/ -f2-)
    case " ${ZIAX_MIRROR_FROM:-} " in
      *" $host "*) ;;
      *)
        echo "Quay mirror: $image is on $host, which is not copied"
        return 0
        ;;
    esac
    dest="$ZIAX_MIRROR/$path"
    target=$digest

    # A trunk build's record with no sha- tag gets one in the mirror, so that hydration can pin it.
    if [ "${ZIAX_MIRROR_SHA_TAGS:-false}" = true ] && [ "$ref" = "${ZIAX_MIRROR_TRUNK_REF:-refs/heads/production}" ] &&
      ! echo " $tags " | grep -q -E ' sha-[0-9a-f]{12} ' && echo "$revision" | grep -q -E '^[0-9a-f]{40}$'; then
      sha="sha-$(echo "$revision" | cut -c1-12)"
      tags="$sha $tags"
      echo "Quay mirror: $image was built from $ref, so the mirror tags it $sha as well"
    fi

    # The sha- tag first: if the mirror keeps an earlier build of this commit, the other tags follow that build.
    for tag in $tags; do
      echo "$tag" | grep -q -E '^sha-[0-9a-f]{12}$' || continue
      status=0
      current=$(mirror_lookup "$dest:$tag") || status=$?
      case $status in
        0)
          if [ "$current" = "$digest" ]; then
            echo "Quay mirror: $dest:$tag is already $digest"
            mirror_same=$((mirror_same + 1))
          else
            echo "Quay mirror: $dest:$tag is $current from an earlier build of this commit; it is immutable, so it" \
              "keeps that image, and the other tags point there too (this build's is $digest)"
            mirror_kept=$((mirror_kept + 1))
            target=$current
          fi
          ;;
        1)
          if "$mirror_crane" copy "$host/$path@$digest" "$dest:$tag" >/dev/null 2>"$mirror_err"; then
            echo "Quay mirror: copied $host/$path@$digest to $dest:$tag"
            mirror_copied=$((mirror_copied + 1))
            mirror_mark "$dest" "$tag"
          else
            mirror_fail "could not copy $host/$path@$digest to $dest:$tag: $(tail -1 "$mirror_err")"
            return 0
          fi
          ;;
        *)
          mirror_fail "could not look up $dest:$tag: $(tail -1 "$mirror_err")"
          return 0
          ;;
      esac
    done

    for tag in $tags; do
      echo "$tag" | grep -q -E '^sha-[0-9a-f]{12}$' && continue
      status=0
      current=$(mirror_lookup "$dest:$tag") || status=$?
      if [ "$status" = 0 ] && [ "$current" = "$target" ]; then
        echo "Quay mirror: $dest:$tag is already $target"
        mirror_same=$((mirror_same + 1))
        continue
      fi
      if [ "$status" = 2 ]; then
        mirror_fail "could not look up $dest:$tag: $(tail -1 "$mirror_err")"
        continue
      fi
      if [ "$target" = "$digest" ]; then
        if "$mirror_crane" copy "$host/$path@$digest" "$dest:$tag" >/dev/null 2>"$mirror_err"; then
          echo "Quay mirror: copied $host/$path@$digest to $dest:$tag"
          mirror_copied=$((mirror_copied + 1))
        else
          mirror_fail "could not copy $host/$path@$digest to $dest:$tag: $(tail -1 "$mirror_err")"
        fi
      elif "$mirror_crane" tag "$dest@$target" "$tag" >/dev/null 2>"$mirror_err"; then
        echo "Quay mirror: pointed $dest:$tag at $target, the build this commit's sha- tag keeps"
        mirror_copied=$((mirror_copied + 1))
      else
        mirror_fail "could not point $dest:$tag at $target: $(tail -1 "$mirror_err")"
      fi
    done
  }

  mirror_records=()
  if [ -f image.json ]; then
    mirror_records+=(image.json)
  fi
  if [ -d build/images ]; then
    while IFS= read -r mirror_file; do
      mirror_records+=("$mirror_file")
    done < <(find build/images -type f -name '*.json' | sort)
  fi

  if [ "${#mirror_records[@]}" = 0 ]; then
    echo "Quay mirror: the build recorded no images"
  elif ! command -v python3 >/dev/null; then
    mirror_fail "python3 is not installed on this agent, so the records cannot be read"
  elif ! mirror_install_crane; then
    mirror_fail "could not install crane"
  else
    # Called through ||, so a surprise inside a record is a warning, never the end of a build that has published.
    for mirror_file in "${mirror_records[@]}"; do
      mirror_record "$mirror_file" || mirror_fail "stopped on $mirror_file"
    done
  fi
  rm -f "$mirror_err"

  echo "Quay mirror to $ZIAX_MIRROR: $mirror_copied tag(s) copied, $mirror_same already there," \
    "$mirror_kept kept from an earlier build, $mirror_failed failed; $mirror_marked sha- tag(s) marked immutable," \
    "$mirror_unmarked left mutable"
  if [ "$mirror_unmarked" -gt 0 ]; then
    echo "##teamcity[addBuildTag 'quay-sha-mutable']"
  fi
  if [ "$mirror_failed" -gt 0 ]; then
    if [ "${ZIAX_MIRROR_REQUIRED:-false}" = true ]; then
      echo "##teamcity[buildProblem description='$(mirror_tc "Copying to $ZIAX_MIRROR failed $mirror_failed time(s); see the build log")']"
      exit 1
    fi
    echo "##teamcity[addBuildTag 'quay-mirror-failed']"
  fi
fi
