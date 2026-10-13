<p align="center">
  <img alt="Docker Stack Deploy logo" width="200px" src="./docs/icon.png">
</p>

<h1 align="center">
  Docker Stack Deploy
</h1>

<p align="center">
  Gitea / GitHub Action and Docker image to deploy a Docker stack on a remote Docker Swarm over SSH.
</p>

---

- [How it works](#how-it-works)
- [Configuration options](#configuration-options)
- [Using the Action](#using-the-action)
- [Using the Docker image](#using-the-docker-image)
- [Releasing](#releasing)
- [Credits](#credits)

## How it works

1. Optionally logs in to a container registry (so the Swarm nodes can pull private images via `--with-registry-auth`).
2. Optionally loads extra environment variables from an env file, to be interpolated in the stack file(s).
3. Configures an SSH client with your private key (and optional CA-signed certificate), trusts the remote host via `ssh-keyscan` and verifies the connection.
4. Runs `docker stack deploy` against the Swarm manager using `DOCKER_HOST=ssh://<user>@<host>:<port>`.
5. Waits until all services of the stack have converged (via [`docker-stack-wait`](https://github.com/sudo-bmitch/docker-stack-wait)), failing if `deploy_timeout` is exceeded.

**Requirements on the remote host:** an SSH-reachable Docker Swarm manager node, and a `remote_user` allowed to run `docker` commands (e.g. member of the `docker` group).

## Configuration options

| Action input | Environment variable | Description | Required | Default |
| --- | --- | --- | :---: | --- |
| `remote_host` | `REMOTE_HOST` | Hostname or IP of the Docker Swarm manager node. | ✅ | |
| `remote_port` | `REMOTE_PORT` | SSH port of the manager node. | | `22` |
| `remote_user` | `REMOTE_USER` | User with SSH access and Docker privileges on the manager node. | ✅ | |
| `remote_private_key` | `REMOTE_PRIVATE_KEY` | SSH private key (content). | ✅ \* | |
| `remote_private_key_file` | `REMOTE_PRIVATE_KEY_FILE` | Path to a file containing the SSH private key. Overrides `remote_private_key`. | ✅ \* | |
| `with_cert` | `WITH_CERT` | Set to `true` to authenticate with a CA-signed SSH certificate. | | `false` |
| `remote_private_key_cert` | `REMOTE_PRIVATE_KEY_CERT` | SSH certificate (`*-cert.pub` content). Required when `with_cert` is `true`. | | |
| `remote_private_key_cert_file` | `REMOTE_PRIVATE_KEY_CERT_FILE` | Path to the SSH certificate file. Overrides `remote_private_key_cert`. | | |
| `registry` | `REGISTRY` | Container registry to log in to (empty = Docker Hub). | | |
| `username` | `USERNAME` | Container registry username. | | |
| `password` | `PASSWORD` | Container registry password or token. | | |
| `stack_file` | `STACK_FILE` | Path to the stack file. Multiple files can be given comma-separated (e.g. `stack.yml,stack.prod.yml`): they are merged in order, later files overriding earlier ones. | ✅ | |
| `stack_name` | `STACK_NAME` | Name of the stack to deploy. | ✅ | |
| `env_file` | `ENV_FILE` | Path to a `KEY=VALUE` file whose variables are exported before the deploy, so they can be used for `${VAR}` interpolation in the stack file. Lines starting with `#` are ignored. | | |
| `deploy_timeout` | `DEPLOY_TIMEOUT` | Seconds to wait for the services to converge before failing. | | `600` |
| `debug` | `DEBUG` | Set to `1` for verbose logging (including `ssh -vvv`). | | `0` |
| `stack_param` | `STACK_PARAM` | Reserved — currently not used by the deploy script. | | |

\* One of `remote_private_key` or `remote_private_key_file` is required.

> [!WARNING]
> With `debug` enabled, the content of `env_file` and the environment are printed to the log. Do not enable it when those contain secrets.

## Using the Action

Add a workflow file under `.gitea/workflows/` (Gitea Actions) or `.github/workflows/` (GitHub Actions) and configure it with the options above.

### Deploying public images

```yaml
name: Deploy Staging

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout codebase
        uses: actions/checkout@v4

      - name: Deploy
        uses: https://gitea.likablehair.it/Likablehair/docker-stack-deploy@v1.3.0
        with:
          remote_host: ${{ secrets.REMOTE_HOST }}
          remote_user: ${{ secrets.REMOTE_USER }}
          remote_private_key: ${{ secrets.REMOTE_PRIVATE_KEY }}
          stack_file: "stacks/app.yml"
          stack_name: "app-staging"
```

### Deploying private images

The registry credentials are forwarded to the Swarm nodes so they can pull private images.

```yaml
name: Deploy Live

on:
  push:
    tags:
      - '*.*.*'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout codebase
        uses: actions/checkout@v4

      - name: Deploy
        uses: https://gitea.likablehair.it/Likablehair/docker-stack-deploy@v1.3.0
        with:
          registry: "cr.likablehair.it"
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
          remote_host: ${{ secrets.REMOTE_HOST }}
          remote_user: ${{ secrets.REMOTE_USER }}
          remote_private_key: ${{ secrets.REMOTE_PRIVATE_KEY }}
          stack_file: "stacks/app.yml"
          stack_name: "app-live"
```

### Merging multiple stack files

Use a shared base file plus environment-specific overrides:

```yaml
      - name: Deploy
        uses: https://gitea.likablehair.it/Likablehair/docker-stack-deploy@v1.3.0
        with:
          remote_host: ${{ secrets.REMOTE_HOST }}
          remote_user: ${{ secrets.REMOTE_USER }}
          remote_private_key: ${{ secrets.REMOTE_PRIVATE_KEY }}
          stack_file: "stacks/app.yml, stacks/app.prod.yml"
          stack_name: "app-live"
```

This runs `docker stack deploy -c stacks/app.yml -c stacks/app.prod.yml app-live`.

### Passing variables to the stack file

Write the variables to a file in the workspace and point `env_file` to it:

```yaml
      - name: Prepare environment
        run: |
          echo "IMAGE_TAG=${{ github.ref_name }}" > .env.deploy
          echo "DB_PASSWORD=${{ secrets.DB_PASSWORD }}" >> .env.deploy

      - name: Deploy
        uses: https://gitea.likablehair.it/Likablehair/docker-stack-deploy@v1.3.0
        with:
          remote_host: ${{ secrets.REMOTE_HOST }}
          remote_user: ${{ secrets.REMOTE_USER }}
          remote_private_key: ${{ secrets.REMOTE_PRIVATE_KEY }}
          stack_file: "stacks/app.yml"
          stack_name: "app-live"
          env_file: ".env.deploy"
```

In `stacks/app.yml` you can then reference `${IMAGE_TAG}` and `${DB_PASSWORD}`.

### Authenticating with an SSH certificate

```yaml
        with:
          # ...
          remote_private_key: ${{ secrets.REMOTE_PRIVATE_KEY }}
          with_cert: "true"
          remote_private_key_cert: ${{ secrets.REMOTE_PRIVATE_KEY_CERT }}
```

## Using the Docker image

The image `cr.likablehair.it/docker-stack-deploy` can be used directly, passing the configuration options as environment variables. Mount the directory containing your stack file(s) at `/github/workspace` (the working directory); relative paths are resolved from there.

### Local machine

Create a file named `.env_deploy`:

```dotenv
REGISTRY=cr.likablehair.it
USERNAME=foo_usr
PASSWORD=averylargepasswordortoken
REMOTE_HOST=192.168.17.2
REMOTE_PORT=22
REMOTE_USER=user
STACK_FILE=path/to/stack.yml
STACK_NAME=mystack
DEBUG=1
```

Then run:

```shell
docker run --rm \
  -v "$(pwd)":/github/workspace \
  --env-file=.env_deploy \
  -e REMOTE_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
  cr.likablehair.it/docker-stack-deploy:latest
```

### GitLab CI

In your GitLab project, go to **Settings → CI/CD → Variables** and add the required variables (`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_KEY`, `REGISTRY`, `REGISTRY_USER`, `REGISTRY_PASSWORD`).

Then add a `deploy` job to your `.gitlab-ci.yml`:

```yaml
deploy:
  stage: deploy
  image: docker:27
  services:
    - docker:27-dind
  variables:
    DEPLOY_IMAGE: cr.likablehair.it/docker-stack-deploy:latest
  script:
    - docker run --rm
        -v "$(pwd)":/github/workspace
        -e REGISTRY="${REGISTRY}"
        -e USERNAME="${REGISTRY_USER}"
        -e PASSWORD="${REGISTRY_PASSWORD}"
        -e REMOTE_HOST="${DEPLOY_HOST}"
        -e REMOTE_PORT=22
        -e REMOTE_USER="${DEPLOY_USER}"
        -e REMOTE_PRIVATE_KEY="${DEPLOY_KEY}"
        -e STACK_FILE=stacks/app.yml
        -e STACK_NAME=app
        "${DEPLOY_IMAGE}"
```

## Releasing

Pushing a tag matching `v*.*.*` triggers the [release workflow](.github/workflows/release.yml), which builds the image and pushes it to `cr.likablehair.it/docker-stack-deploy` tagged with the full version, `major.minor`, `major` and the commit SHA.

```shell
git tag -a v1.4.0 -m "Release 1.4.0"
git push origin v1.4.0
```

To build the image locally: `docker build -t docker-stack-deploy .`

Please don't push directly to `master`: open a pull request and have someone else review and merge it.

## Credits

This project is a fork of [kitconcept/docker-stack-deploy](https://github.com/kitconcept/docker-stack-deploy) by [kitconcept GmbH](https://kitconcept.com).

It bundles the `docker-stack-wait` script by Brandon Mitchell, available on [GitHub](https://github.com/sudo-bmitch/docker-stack-wait).

The logo is based on the [rocket icon](https://freeicons.io/seo/rocket-icon-24668#).

## License

Licensed under the [MIT License](./LICENSE).
