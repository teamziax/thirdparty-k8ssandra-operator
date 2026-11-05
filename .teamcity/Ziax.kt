/*
 * Ziax conventions for TeamCity pipelines on tc.ops.ziax.ltd.
 *
 * Every repository that builds there carries an identical copy of this file, publish-image.sh, mirror-images.sh and
 * mirror-images-test.sh in its .teamcity/ directory, so change them in all of those repositories together. The
 * conventions themselves are recorded in the cubecraft knowledge bundle under ci/.
 */

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.PullRequests
import jetbrains.buildServer.configs.kotlin.buildFeatures.commitStatusPublisher
import jetbrains.buildServer.configs.kotlin.buildFeatures.dockerRegistryConnections
import jetbrains.buildServer.configs.kotlin.buildFeatures.pullRequests
import jetbrains.buildServer.configs.kotlin.buildSteps.ScriptBuildStep
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import java.io.File

/** The Root project connection "OVH registry (Ziax) — push robot". */
const val OVH_REGISTRY_CONNECTION = "PROJECT_EXT_3"

/** Quay on man1-prod1, which is taking over from the OVH registry. */
const val QUAY_REGISTRY = "cr.ziax.ltd"

/**
 * CI's token for Quay's API, as a TeamCity secure value: an OAuth token with scope repo:write, issued to a regular Quay
 * user, because Quay's API takes OAuth tokens and sessions only, never a robot's login. Its value is generated only in
 * the Cubecraft, ClusterConfiguration and ZiaxConfiguration projects, never in the Root project, so no other project,
 * the Third-Party forks' included, can resolve it. Before another project's builds pass it on, generate it there too
 * (Project Settings, Actions, Generate token for a secure value).
 */
const val QUAY_API_TOKEN = "credentialsJSON:f7dd3eb9-8ee2-47eb-868b-f860d11baa32"

/**
 * An organization on Quay, one per owner, and the Root project connection "Quay MAN1 <organization>" that logs in as
 * its <organization>+teamcity robot. The robot can push to its own organization only.
 *
 * [apiToken] is the TeamCity secure value of an OAuth token for Quay's API with scope repo:write on the organization:
 * [QUAY_API_TOKEN] for each of them. mirror-images.sh marks each sha- tag it creates immutable with it, with an
 * expiry, and hydrate.sh renews the expiry of the sha- tags the release branches pin. Without one, an organization's
 * sha- tags are created mutable, with no expiry and a warning.
 */
enum class QuayOrganization(val connection: String, val apiToken: String? = null) {
    ZIAX("PROJECT_EXT_6", QUAY_API_TOKEN),
    ROCKET("PROJECT_EXT_7", QUAY_API_TOKEN),
    CUBECRAFT("PROJECT_EXT_8", QUAY_API_TOKEN);

    /** Where mirror-images.sh copies images to: cr.ziax.ltd/<organization>. */
    val mirror get() = "$QUAY_REGISTRY/${name.lowercase()}"
}

/**
 * A script step that runs inside [image], so the toolchain comes from the image instead of the agent. TeamCity mounts
 * the checkout at the same path, runs the container as root and hands file ownership back to the agent afterwards.
 */
fun BuildSteps.inContainer(
    stepName: String,
    image: String,
    runParameters: String = "",
    script: String,
    init: ScriptBuildStep.() -> Unit = {},
) = script {
    name = stepName
    scriptContent = script
    dockerImage = image
    dockerImagePlatform = ScriptBuildStep.ImagePlatform.Linux
    dockerPull = true
    dockerRunParameters = runParameters
    init()
}

/** Reports the build to GitHub as a commit status, authenticated by the VCS root's GitHub App token. */
fun BuildFeatures.githubCommitStatus() = commitStatusPublisher {
    vcsRootExtId = "${DslContext.settingsRoot.id}"
    publisher = github {
        githubUrl = "https://api.github.com"
        authType = vcsRoot()
    }
}

/**
 * Builds open pull requests as pull/<number> branches. Drafts are skipped; authors are not filtered, because bots
 * such as Dependabot and Renovate are not organisation members.
 */
fun BuildFeatures.githubPullRequests() = pullRequests {
    vcsRootExtId = "${DslContext.settingsRoot.id}"
    provider = github {
        authType = vcsRoot()
        filterAuthorRole = PullRequests.GitHubRoleFilter.EVERYBODY
        ignoreDrafts = true
    }
}

/**
 * Logs the build in to the OVH registry, and to [quay] when one is named, and out again when it finishes. A build logs
 * in to one Quay organization at most: Docker keeps one login per registry host.
 *
 * A login that a registry refuses or does not answer fails the build, but the build still runs its steps: BlueMap's
 * first Publish image failed its OVH login on 2026-09-24 and still built.
 */
fun BuildFeatures.registryLogin(quay: QuayOrganization? = null) = dockerRegistryConnections {
    loginToRegistry = on {
        // The connections a build logs in with are one setting, comma-separated.
        dockerRegistryId = listOfNotNull(OVH_REGISTRY_CONNECTION, quay?.connection).joinToString(",")
    }
}

/**
 * The inputs of mirror-images.sh, which copies what a build pushed to the registry [from] into [organization] on Quay
 * as well, while the two registries run side by side. The build must log in to it: registryLogin(organization).
 *
 * With [shaTags], a record built from production that carries no sha- tag gets sha-<revision> in Quay, so hydration
 * can pin the image. It is for the images hydration subscribes to: every sha- tag is kept until the cleanup job
 * deletes it, and it counts against the organization's quota until then.
 */
fun ParametrizedWithType.quayMirror(
    organization: QuayOrganization,
    from: String = "%ziax.registry.host%",
    shaTags: Boolean = false,
) {
    param("env.ZIAX_MIRROR", organization.mirror)
    param("env.ZIAX_MIRROR_FROM", from)
    if (shaTags) param("env.ZIAX_MIRROR_SHA_TAGS", "true")
    organization.apiToken?.let { password("env.ZIAX_MIRROR_QUAY_TOKEN", it) }
}

/**
 * The inputs publish-image.sh reads. [trunkRef] is the one branch that publishes the moving production tag; it is
 * named explicitly rather than taken from the VCS root's default branch, so pointing the settings at another branch
 * can never publish production from it. With a [mirror], what it pushes is copied to that Quay organization too.
 */
fun ParametrizedWithType.imageContract(
    imageName: String,
    title: String,
    sourceUrl: String,
    trunkRef: String,
    mirror: QuayOrganization? = null,
) {
    param("env.ZIAX_REGISTRY", "%ziax.registry.host%")
    param("env.ZIAX_IMAGE_NAME", imageName)
    param("env.ZIAX_IMAGE_TITLE", title)
    param("env.ZIAX_SOURCE_URL", sourceUrl)
    param("env.ZIAX_TRUNK_REF", trunkRef)
    param("env.ZIAX_GIT_REF", "%teamcity.build.vcs.branch.${DslContext.settingsRoot.id}%")
    param("env.ZIAX_COMMIT", "%build.vcs.number%")
    param("env.ZIAX_PUSH", "%deploy.push.enabled%")
    // The registry login goes to a Docker config per agent rather than ~/.docker: the agents share one host and one
    // home directory, so a build finishing on one agent would otherwise log out a push still running on another
    // (TW-56818).
    param("env.DOCKER_CONFIG", "%teamcity.agent.home.dir%/system/.docker")
    mirror?.let { quayMirror(it) }
}

/**
 * Builds the image and pushes it when deploy.push.enabled is true, then copies it to Quay if the image contract names
 * a mirror. The scripts are read in when TeamCity compiles the settings, so they also run for branches that have no
 * .teamcity/ directory of their own.
 */
fun BuildSteps.publishImage() = script {
    name = "Build and push the image"
    scriptContent = scriptFile("publish-image.sh") + "\n" + scriptFile("mirror-images.sh")
}

/**
 * The contents of a script kept beside the settings, read when TeamCity compiles them. A shell script inlined in
 * Kotlin needs every "$" escaped; one kept in its own file does not, but it must contain no percent sign, because
 * TeamCity reads a pair of them in a step script as a parameter reference. Pass inputs as env.* parameters instead.
 */
fun scriptFile(name: String): String = File(DslContext.baseDir, name).readText()
