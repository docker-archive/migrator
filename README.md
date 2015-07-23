mbentley/migrator
=================

docker image to migrate Docker images from a v1 registry to a v2 registry

To pull this image:
`docker pull mbentley/migrator`

## Usage

```
docker run -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e V1_REGISTRY_URL=v1.registry.fqdn \
  -e V2_REGISTRY_URL=v2.registry.fqdn \
  mbentley/migrator
```

## Prerequisites
This migration assumes that you have a v1 registry and you are planning on migrating to a v2 registry.  The new v2 registry can either be set up using a different DNS name or the same DNS name.  Both scenarios work in this case.  If you are utilizing the same DNS name for your new v2 registry, set both `V1_REGISTRY_URL` and `V2_REGISTRY_URL` to the same value.

It is suggested that you run this container on a Docker engine that is located near your registry as you will need to pull down every image from your v1 registry and push it back to the v2 registry to complete the migration.  This also means that you will need enough disk space on your local Docker engine to store all of the images.

## How Migration Works
The migration occurs using an automated script inside of the Docker container.  Running using the above usage will work as expected.

1. (Optional) Login to the v1 registry
 - If you do not have authentication enabled, leave the username blank when prompted
2. Query the v1 registry for a list of all repositories
3. With the list of images, query the v1 registry for all tags for each repository.  This becomes the list of all images w/tags that you need to migrate
4. Using a Docker engine, pull all images (including each tag)
5. Once all images are pulled, there are a few options for next steps:
 1. If the same DNS record will be used for the v1 and v2 registries:
   - Have user switch the DNS record over to the new server's IP or if same box to be used, stop the v1 registry and start the v2 registry
 2. If a different DNS record will be used for the v1 and v2 registries:
   - Re-tag all images to change the tagging from the old DNS record to the new one
6. (Optional) Login to the v2 registry
 - If you do not have authentication enabled, leave the username blank when prompted
7. Push all images and tags to the v2 registry
8. ~~Verify image lists match from the v1 to v2~~ (impossible right now since we can't query the v2 registry)
9. Cleanup local docker engine to remove images

[![asciicast](https://asciinema.org/a/1ahni6vlnjh2plq8quvddegva.png)](https://asciinema.org/a/1ahni6vlnjh2plq8quvddegva)

## Logging Migration Output
If you need to log the output from migrator, add `2>&1 | tee migration.log` to the end of the command shown above to capture the output to a file of your choice.
