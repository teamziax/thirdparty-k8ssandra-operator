#!/usr/bin/env bash
# Publishes one Docker image to the Ziax OVH registry: the Ziax image contract as TeamCity runs it.
#
# settings.kts reads this file into the "Publish image" build step when TeamCity compiles the
# settings, so a branch that predates .teamcity/ still publishes with the default branch's copy.
# It must not contain a percent sign, because TeamCity reads a pair of them in a step script as a
# parameter reference. Every input therefore arrives as an environment variable that settings.kts
# sets from build parameters:
#
#   ZIAX_REGISTRY     registry host (the Root parameter ziax.registry.host)
#   ZIAX_IMAGE_NAME   repository in the registry, e.g. services/bluemap-cli
#   ZIAX_IMAGE_TITLE  org.opencontainers.image.title
#   ZIAX_SOURCE_URL   org.opencontainers.image.source
#   ZIAX_GIT_REF      full ref being built, e.g. refs/heads/master
#   ZIAX_TRUNK_REF    the one ref that publishes the moving production tag
#   ZIAX_COMMIT       full commit sha being built
#   ZIAX_PUSH         "true" pushes; anything else only builds and tags (deploy.push.enabled)
#   ZIAX_CONTEXT      docker build context, default "."
#   ZIAX_DOCKERFILE   Dockerfile, default "Dockerfile" inside the context
#   BUILD_URL         set by TeamCity; stamped on the image so it leads back to this build
#
# Every build gets two tags:
#   sha-<first 12 hex of the commit>  immutable. Deploy by digest; this tag keeps the manifest
#                 referenced, because the OVH registry prunes untagged manifests and a bare
#                 digest pin can stop resolving.
#   production    moving, published only from ZIAX_TRUNK_REF, or
#   <branch>      moving, from any other branch: the branch name with every character outside
#                 A-Z a-z 0-9 _ . - turned into "-". A name that would read as production,
#                 latest or sha-* gets a "branch-" prefix, so no branch can stand in for the trunk.
# Pull-request refs are refused: images come from branch heads only.
#
# Leaves image.json (image, tags, digest, whether it was pushed) for later builds to consume.
set -euo pipefail

: "${ZIAX_REGISTRY:?}" "${ZIAX_IMAGE_NAME:?}" "${ZIAX_IMAGE_TITLE:?}" "${ZIAX_SOURCE_URL:?}"
: "${ZIAX_GIT_REF:?}" "${ZIAX_TRUNK_REF:?}" "${ZIAX_COMMIT:?}"
context="${ZIAX_CONTEXT:-.}"
dockerfile="${ZIAX_DOCKERFILE:-$context/Dockerfile}"

registry="$(echo "$ZIAX_REGISTRY" | sed -e 's#^https\{0,1\}://##' -e 's#/*$##')"
image="$registry/$ZIAX_IMAGE_NAME"
sha_tag="sha-$(echo "$ZIAX_COMMIT" | cut -c1-12)"

case "$ZIAX_GIT_REF" in
  "$ZIAX_TRUNK_REF")
    alias_tag="production"
    ;;
  refs/heads/*)
    alias_tag="$(echo -n "${ZIAX_GIT_REF#refs/heads/}" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-120)"
    case "$alias_tag" in
      production | latest | sha-* | [.-]*) alias_tag="branch-$alias_tag" ;;
    esac
    ;;
  *)
    echo "##teamcity[buildProblem description='Not publishing $ZIAX_GIT_REF: images are published from branch heads only']"
    exit 1
    ;;
esac

version="$(git describe --tags --always 2>/dev/null || echo "$sha_tag")"
echo "Building $image:$sha_tag and :$alias_tag from $ZIAX_GIT_REF ($version)"

docker build --pull \
  --file "$dockerfile" \
  --tag "$image:$sha_tag" \
  --tag "$image:$alias_tag" \
  --label "org.opencontainers.image.title=$ZIAX_IMAGE_TITLE" \
  --label "org.opencontainers.image.created=$(date -u -Iseconds)" \
  --label "org.opencontainers.image.source=$ZIAX_SOURCE_URL" \
  --label "org.opencontainers.image.revision=$ZIAX_COMMIT" \
  --label "org.opencontainers.image.version=$version" \
  --label "org.opencontainers.image.vendor=Ziax LTD" \
  --label "ltd.ziax.ci.build-url=${BUILD_URL:-}" \
  "$context"

pushed=false
digest=""
if [ "${ZIAX_PUSH:-false}" = "true" ]; then
  docker push "$image:$sha_tag"
  docker push "$image:$alias_tag"
  pushed=true
  digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image:$sha_tag" | grep -m1 "^$image@" || true)"
  echo "##teamcity[addBuildTag '$alias_tag']"
  echo "##teamcity[buildStatus text='{build.status.text}; pushed $image:$alias_tag']"
  echo "Pushed $image:$sha_tag and :$alias_tag; pin ${digest:-<digest unavailable, read it from the push output>}"
else
  echo "##teamcity[buildStatus text='{build.status.text}; built $image:$alias_tag, not pushed (deploy.push.enabled is not true)']"
  echo "Not pushing: deploy.push.enabled is '${ZIAX_PUSH:-}'"
fi

cat > image.json <<JSON
{
  "image": "$image",
  "tags": ["$sha_tag", "$alias_tag"],
  "digest": "$digest",
  "pushed": $pushed,
  "ref": "$ZIAX_GIT_REF",
  "revision": "$ZIAX_COMMIT"
}
JSON
echo "Wrote image.json"
