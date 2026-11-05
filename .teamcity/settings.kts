import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.perfmon
import jetbrains.buildServer.configs.kotlin.triggers.vcs

/*
 * TeamCity pipeline for teamziax/thirdparty-k8ssandra-operator, our fork of k8ssandra/k8ssandra-operator.
 *
 * The fork carries changes we run before they are upstream, on release branches named ziax/v<major>.<minor>, each cut
 * from an upstream release tag: ziax/v1.34 is v1.34.0 plus them. Their images are what cluster-configuration's
 * components/k8ssandra-operator deploys. .github/ is left as upstream has it, so upstream merges apply cleanly;
 * upstream never touches .teamcity/.
 *
 * TeamCity loads this directory through versioned settings on Third-Party / k8ssandra-operator from the default branch,
 * main, and builds of every branch use those settings, so the release branches, which carry no .teamcity/, still build
 * and publish. Ziax.kt, publish-image.sh and mirror-images.sh, with its test, are shared with the other repositories;
 * README.md says how to check a change locally before it lands.
 */

// TeamCity Cloud has refused settings newer than 2026.1 since its update of 2026-11-02 ("settings version 2026.2 is not
// supported").
version = "2026.1"

project {
    params {
        // This repository publishes from TeamCity. The Root project defaults this to false, which keeps the deploy
        // jobs ported from repositories that have not cut over yet build-only.
        param("deploy.push.enabled", "true")
    }

    buildType(Ci)
    buildType(PublishImage)
}

object Ci : BuildType({
    id("Ci")
    name = "CI"
    description = "make test: the generated manifests, gofmt, go vet, golangci-lint, and the unit and envtest suites"

    vcs {
        root(DslContext.settingsRoot)
    }

    steps {
        // Upstream's own gate (.github/workflows/test_and_build_image.yaml runs the same target). The Go toolchain
        // comes from go.mod through GOTOOLCHAIN, and the module and build caches are a Docker volume per agent, so
        // they stay warm and no two builds ever share one.
        inContainer(
            "make test",
            image = "golang:1.26",
            runParameters = "-e GOMODCACHE=/go-cache/mod -e GOCACHE=/go-cache/build " +
                "-v teamcity-go-%teamcity.agent.name%:/go-cache",
            script = """
                set -eu
                # The checkout belongs to the agent user and the container runs as root; without this, git refuses
                # the repository and the Makefile's version stamping fails.
                git config --global --add safe.directory '*'
                make test
            """.trimIndent(),
        )
    }

    artifactRules = "coverage.out"

    triggers {
        vcs {
            branchFilter = """
                +:*
                -:dependabot/*
            """.trimIndent()
        }
    }

    features {
        perfmon {}
        githubPullRequests()
        githubCommitStatus()
    }

    requirements {
        exists("docker.server.version")
    }

    failureConditions {
        executionTimeoutMin = 60
    }
})

object PublishImage : BuildType({
    id("PublishImage")
    name = "Publish image"
    description = "operators/k8ssandra-operator on the OVH registry, copied to Quay's ziax organization: production " +
        "and sha-<commit> from ziax/v1.34, <branch> and sha-<commit> from any other branch but main"

    vcs {
        root(DslContext.settingsRoot)
    }

    params {
        imageContract(
            imageName = "operators/k8ssandra-operator",
            title = "k8ssandra-operator",
            sourceUrl = "https://github.com/teamziax/thirdparty-k8ssandra-operator",
            // The release branch the clusters run. Move it to the next ziax/v<major>.<minor> when we rebase onto a
            // newer upstream release.
            trunkRef = "refs/heads/ziax/v1.34",
            // While Quay runs beside the OVH registry, what this pushes is copied there too.
            mirror = QuayOrganization.ZIAX,
        )
    }

    steps {
        // The Dockerfile builds the operator from source in its own golang stage.
        publishImage()
    }

    // The digest each build pushed, which cluster-configuration pins.
    artifactRules = "image.json"

    dependencies {
        // Only a commit that passes CI publishes.
        snapshot(Ci) {
            onDependencyFailure = FailureAction.FAIL_TO_START
        }
    }

    triggers {
        // Every branch push publishes except main, which follows upstream's development and is never deployed, so a
        // feature branch can be tried on a cluster. Pull-request refs never reach this configuration because only
        // CI carries the Pull Requests feature.
        vcs {
            branchFilter = """
                +:*
                -:main
                -:dependabot/*
            """.trimIndent()
        }
    }

    features {
        perfmon {}
        registryLogin(QuayOrganization.ZIAX)
        githubCommitStatus()
    }

    requirements {
        exists("docker.server.version")
    }

    failureConditions {
        executionTimeoutMin = 30
    }
})
