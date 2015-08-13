docker/migrator
=================

Tool to migrate Docker images from a v1 registry to a v2 registry

To pull this image:
`docker pull docker/migrator`

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

 * `V1_REGISTRY` - DNS hostname of your v1 registry (Do not include `https://`)
 * `V2_REGISTRY` - DNS hostname of your v2 registry (Do not include `https://`)

#### Optional

 * `ERROR_ACTION` - Sets the default action on error for pushes and pulls
  * `prompt` - (_Default_) Prompt for user input as to what action to take on error
  * `retry` - Retry the failed action on error (may cause infinite loop of failure)
  * `skip` - Log the error and continue migration on error
  * `abort` - Abort the migration on error
 * `USER_PROMPT` - Sets the default action for user prompts (non-error)
  * `true` - (_Default_) Prompts user for input/validation
  * `false` - Skips user prompt and automatically proceeds
 * `V1_USERNAME` - Username used for `docker login` to the v1 registry
 * `V1_PASSWORD` - Password used for `docker login` to the v1 registry
 * `V1_EMAIL` - Email used for `docker login` to the v1 registry
 * `V2_USERNAME` - Username used for `docker login` to the v2 registry
 * `V2_PASSWORD` - Password used for `docker login` to the v2 registry
 * `V2_EMAIL` - Email used for `docker login` to the v2 registry

*Note*: You must use all three variables (`V1_USERNAME`, `V1_PASSWORD`, and `V1_EMAIL` or `V2_USERNAME`, `V2_PASSWORD`, and `V2_EMAIL`) for the given automated `docker login` to function properly.  Omitting one will prompt the user for input of all three.

## Prerequisites
This migration tool assumes the following:

 * You have a v1 registry and you are planning on migrating to a v2 registry
 * Both registries are running over HTTPS; HTTP is not supported by this tool
 * The new v2 registry can either be running using a different DNS name or the same DNS name as the v1 registry - both scenarios work in this case.  If you are utilizing the same DNS name for your new v2 registry, set both `V1_REGISTRY` and `V2_REGISTRY` to the same value.

It is suggested that you run this container on a Docker engine that is located near your registry as you will need to pull down every image from your v1 registry and push it back to the v2 registry to complete the migration.  This also means that you will need enough disk space on your local Docker engine to temporarily store all of the images.

## How Migration Works
The migration occurs using an automated script inside of the Docker container.  Running using the above usage will work as expected.

1. Login to the v1 registry (_Optional_)
 - If you do not have authentication enabled, leave the username blank when prompted
2. Query the v1 registry for a list of all repositories
3. With the list of images, query the v1 registry for all tags for each repository.  This becomes the list of all images w/tags that you need to migrate
4. Using a Docker engine, pull all images (including each tag)
5. Once all images are pulled, there are a few options for next steps:
 1. If the same DNS record will be used for the v1 and v2 registries:
   - Have user switch the DNS record over to the new server's IP or if same box to be used, stop the v1 registry and start the v2 registry
 2. If a different DNS record will be used for the v1 and v2 registries:
   - Re-tag all images to change the tagging from the old DNS record to the new one
6. Login to the v2 registry (_Optional_)
 - If you do not have authentication enabled, leave the username blank when prompted
7. Push all images and tags to the v2 registry
8. Verify v1 to v2 image migration was successful (not yet implemented)
9. Cleanup local docker engine to remove images

[![asciicast](https://asciinema.org/a/23844.png)](https://asciinema.org/a/23844)

## Logging Migration Output
If you need to log the output from migrator, add `2>&1 | tee migration.log` to the end of the command shown above to capture the output to a file of your choice.
