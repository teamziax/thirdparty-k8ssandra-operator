# TeamCity pipeline

This fork builds and publishes on [TeamCity](https://ziax.teamcity.com/project/ThirdParty_K8ssandraOperator), not GitHub Actions. The pipeline is Kotlin DSL:

- `settings.kts` is this repository's pipeline:
  - **CI** runs `make test`, upstream's own gate, on every branch and pull request.
  - **Publish image** builds `operators/k8ssandra-operator` from the repository's Dockerfile on every branch push except `main`. It pushes to the OVH registry and copies to Quay as `cr.ziax.ltd/ziax/operators/k8ssandra-operator`, but only after CI passes on the same commit.
- `Ziax.kt`, `publish-image.sh`, `mirror-images.sh` and `mirror-images-test.sh` are shared conventions. Every repository on our TeamCity carries identical copies, so change them everywhere at once.

TeamCity reads this directory from the default branch, `main`, through versioned settings, and the project is read-only in the TeamCity UI: change the pipeline here, through a pull request. Builds of every branch use the default branch's settings. To try a pipeline change before it merges, push the branch and use **Run custom build → use settings from VCS** on it.

## Branches and tags

- `main` follows upstream's `main`. Sync it from upstream; it's never deployed.
- `ziax/v<major>.<minor>`, e.g. `ziax/v1.34`, is an upstream release tag (`v1.34.0`) plus the changes we run before they are upstream. It's the trunk: its builds publish `production` and `sha-<first 12 hex of the commit>`. cluster-configuration deploys a `sha-` tag by digest.
- Any other branch, such as a feature branch for a change on its way into a release branch and upstream, publishes `<branch>` and `sha-<commit>`, so it can be tried on a cluster.

When we move to a newer upstream release, cut `ziax/v<next>` from its tag, rebase or cherry-pick our changes onto it, and move `trunkRef` in `settings.kts`.

## First-time setup (an administrator, once)

1. Under **Third-Party**, create the project `k8ssandra-operator` (id `ThirdParty_K8ssandraOperator`) with this repository as its VCS root, and enable versioned settings from `main`: Kotlin, portable DSL, settings from VCS, UI editing off, secure values outside VCS.
2. Generate CI's Quay API token in the project (Project Settings → Actions → Generate token for a secure value) with the value of `QUAY_API_TOKEN` in `Ziax.kt`. Without it the Quay mirror can't mark its `sha-` tags immutable; see the comment on `QUAY_API_TOKEN`.
3. Run the first CI and Publish image builds by hand. A new build type's trigger only counts changes detected after it was created.

## Checking a change locally

The DSL for the plugins installed on our server is served by the server itself, so Maven needs a TeamCity access token (Profile → Access Tokens). Put it in a Maven settings file:

```xml
<settings>
  <servers>
    <server>
      <id>teamcity-server</id>
      <configuration>
        <httpHeaders>
          <property><name>Authorization</name><value>Bearer YOUR_TOKEN</value></property>
        </httpHeaders>
      </configuration>
    </server>
  </servers>
</settings>
```

Then compile and generate the settings exactly as the server does:

```sh
mvn -s path/to/that/settings.xml -f .teamcity/pom.xml teamcity-configs:generate
```

It fails on anything the server would reject and writes the resulting configuration to `.teamcity/target/generated-configs/`.
