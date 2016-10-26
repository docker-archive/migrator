docker/migrator
=================

Tool to migrate Docker images from Docker Hub or v1 registry to a v2 registry including Amazon EC2 Container Registry (ECR) 

https://hub.docker.com/r/docker/migrator/

## Usage

```
docker run -it \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e V1_REGISTRY=v1.registry.fqdn \
    -e V2_REGISTRY=v2.registry.fqdn \
    docker/migrator
```

### Environment Variables
The following environment variables can be set:

#### Required

  * `V1_REGISTRY` - DNS hostname of your v1 registry or Docker Hub (Do not include `https://`)
    * If migrating images from Docker Hub, use `docker.io`
  * `V2_REGISTRY` - DNS hostname of your v2 registry (Do not include `https://`)

#### Optional

  * `AWS_ACCESS_KEY` - AWS Access Key supplied as either an environment variable or as a part of your credentials file.
  * `AWS_REGION` - AWS Region, must be specified if using ECR 
  * `AWS_SECRET_ACCESS_KEY` - AWS Secret Access Key supplied as either an environment variable or as a part of your credentials file.
  * `ERROR_ACTION` - Sets the default action on error for pushes and pulls
    * `prompt` - (_Default_) Prompt for user input as to what action to take on error
    * `retry` - Retry the failed action on error (may cause infinite loop of failure)
    * `skip` - Log the error and continue migration on error
    * `abort` - Abort the migration on error
  * `MIGRATION_INCREMENT` - Breaks up migration in chunks of `n` images
    * Defaults to migrating all images at once if not specified
    * Must be a positive integer
    * Only works if source and destination are not the same FQDN
  * `USER_PROMPT` - Sets the default action for user prompts (non-error)
    * `true` - (_Default_) Prompts user for input/validation
    * `false` - Skips user prompt and automatically proceeds
  * `NO_LOGIN`
    * `true` - Skips `docker login` for both the v1 and v2 registries
    * `false` - (_Default_) Prompts user to login to the v1 and v2 registries
  * `V1_NO_LOGIN`
    * `true` - Skips `docker login` for the v1 registry
    * `false` - (_Default_) Prompts user to login to the v1 registry
  * `V2_NO_LOGIN`
    * `true` - Skips `docker login` for the v2 registry
    * `false` - (_Default_) Prompts user to login to the v2 registry
  * `USE_INSECURE_CURL`
    * `true` - Allows curl to perform insecure SSL connections for querying APIs
    * `false` - (_Default_) Require curl to perform secure SSL connections for querying APIs
  * `USE_HTTP`
    * `true` - Allows curl to connect to both the v1 and v2 registries over HTTP
      * *Note*: daemon must also have `--insecure-registry` option set
    * `false` - (_Default_) Requires curl to connect to v1 and v2 registries over HTTPS
  * `V1_USE_HTTP`
    * `true` - Allows curl to connect to v1 registry running over HTTP
      * *Note*: daemon must also have `--insecure-registry` option set
    * `false` - (_Default_) Requires curl to connect to v1 registry over HTTPS
  * `V2_USE_HTTP`
    * `true` - Allows curl to connect to v2 registry running over HTTP
      * *Note*: daemon must also have `--insecure-registry` option set
    * `false` - (_Default_) Requires curl to connect to v2 registry over HTTPS
  * `DOCKER_HUB_ORG` - Docker Hub organization name to migrate images from
    * Defaults to the username used to login to Docker Hub if not provided
  * `V1_REPO_FILTER` - Search filter to limit the scope of the repositories to migrate (uses [grep basic regular expression interpretation](http://www.gnu.org/software/grep/manual/html_node/Basic-vs-Extended.html))
    * *Note*: This only filters the repositories returned from the source registry search API, not the individual tags
  * `V1_TAG_FILTER` - Search filter to limit the scope of the tags to migrate (Plain text matching).
  * `LIBRARY_NAMESPACE` - Sets option to migrate official namespaces (images where there is no namespace provided) to the `library/` namespace (Note: must be set to `true` for DTR 1.4 or greater)
    * `true` - (_Default_) Adds `library` namespace to image names
    * `false` - Keeps images as they are without a namespace
  * Custom CA certificate and Client certificate support - for custom CA and/or client certificate support to your v1 and/or v2 registries, you should utilize a volume to share them into the container by adding the following to your run command:
    * `-v /etc/docker/certs.d:/etc/docker/certs.d:ro`
  * `V1_USERNAME` - Username used for `docker login` to the v1 registry
  * `V1_PASSWORD` - Password used for `docker login` to the v1 registry
  * `V1_EMAIL` - Email used for `docker login` to the v1 registry
  * `V2_USERNAME` - Username used for `docker login` to the v2 registry
  * `V2_PASSWORD` - Password used for `docker login` to the v2 registry
  * `V2_EMAIL` - Email used for `docker login` to the v2 registry

*Note*: You must use all three variables (`V1_USERNAME`, `V1_PASSWORD`, and `V1_EMAIL` or `V2_USERNAME`, `V2_PASSWORD`, and `V2_EMAIL`) for the given automated `docker login` to function properly.  Omitting one will prompt the user for input of all three.

## Prerequisites
This migration tool assumes the following:

  * You have a v1 registry (or Docker Hub) and you are planning on migrating to a v2 registry
  * The new v2 registry can either be running using a different DNS name or the same DNS name as the v1 registry - both scenarios work in this case.  If you are utilizing the same DNS name for your new v2 registry, set both `V1_REGISTRY` and `V2_REGISTRY` to the same value.

It is suggested that you run this container on a Docker engine that is located near your registry as you will need to pull down every image from your v1 registry (or Docker Hub) and push them to the v2 registry to complete the migration.  This also means that you will need enough disk space on your local Docker engine to temporarily store all of the images.  If you have limited disk space, it is suggested that you use the `MIGRATION_INCREMENT` option to migrate `n` number of images at a time.

If you're interested in migrating to an Amazon EC2 Container Registry (ECR) you will additionally need to supply your AWS API keys to the migrator tool. This can be accomplished in one of the two following ways:

```
docker run -it \
    -v ~/.aws:/root/.aws:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e V1_REGISTRY=v1.registry.fqdn \
    -e V2_REGISTRY=v2.registry.fqdn \
docker/migrator

docker run -it \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e AWS_ACCESS_KEY_ID=<key> \
    -e AWS_SECRET_ACCESS_KEY=<secret> \
    -e V1_REGISTRY=v1.registry.fqdn \
    -e V2_REGISTRY=v2.registry.fqdn \
docker/migrator
```

## How Migration Works
The migration occurs using an automated script inside of the Docker container.  Running using the above usage will work as expected.

1. Login to the v1 registry or Docker Hub (_Optional_)
 - If you do not have authentication enabled, leave the username blank when prompted
2. Query the v1 registry or Docker Hub for a list of all repositories
3. With the list of images, query the v1 registry or Docker Hub for all tags for each repository.  This becomes the list of all images with tags that you need to migrate
4. Using a Docker engine, pull all images (including each tag)
5. Once all images are pulled, there are a few options for next steps:
  1. If the same DNS record will be used for the v1 and v2 registries:
    * Have user switch the DNS record over to the new server's IP or if same box to be used, stop the v1 registry and start the v2 registry
  2. If a different DNS record will be used for the v1 and v2 registries:
    * Re-tag all images to change the tagging from the old DNS record to the new one
6. Login to the v2 registry (_Optional_)
  * If you do not have authentication enabled, leave the username blank when prompted
7. Push all images and tags to the v2 registry
8. Verify v1 to v2 image migration was successful (not yet implemented)
9. Cleanup local docker engine to remove images

[![asciicast](https://asciinema.org/a/23844.png)](https://asciinema.org/a/23844)

## Logging Migration Output
If you need to log the output from migrator, add `2>&1 | tee migration.log` to the end of the command shown above to capture the output to a file of your choice.
