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
