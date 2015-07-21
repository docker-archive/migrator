#!/bin/bash

set -e

# verify v1 registry variable has been passed
if [ -z "${V1_REGISTRY_URL}" ]
then
  echo "V1_REGISTRY_URL environment variable required"
  exit 1
fi

# verify v2 registry variable has been passed
if [ -z "${V2_REGISTRY_URL}" ]
then
  echo "V2_REGISTRY_URL environment variable required"
  exit 1
fi

# perform a docker login to the v1 registry
echo "Please login for ${V1_REGISTRY_URL}:"
docker login ${V1_REGISTRY_URL}

# decode username/password for v1 registry auth to query API
V1_AUTH="$(cat ~/.dockercfg | jq -r '."'${V1_REGISTRY_URL}'".auth' | base64 --decode)"

# get list of images in registry
IMAGE_LIST="$(curl -s https://${V1_AUTH}@${V1_REGISTRY_URL}/v1/search?q= | jq -r '.results | .[] | .name')"

# loop through all images in registry to get tags for each
for i in ${IMAGE_LIST}
do
  # get list of tags for image i
  IMAGE_TAGS=$(curl -s https://${V1_AUTH}@${V1_REGISTRY_URL}/v1/repositories/${i}/tags | jq -r 'keys | .[]')

  # loop through tags to create list of full image names w/tags
  for j in ${IMAGE_TAGS}
  do
    # check if an image is a 'library' image without a namespace
    if [ ${i:0:8} = "library/" ]
    then
      # cut off 'library/' from beginning of image
      i="${i:8}"
    fi
    # add image to list
    FULL_IMAGE_LIST="${FULL_IMAGE_LIST} ${i}:${j}"
  done
done

# pull all images to local system
for i in ${FULL_IMAGE_LIST}
do
  docker pull ${V1_REGISTRY_URL}/${i}
  echo
done

if [ "${V1_REGISTRY_URL}" = "${V2_REGISTRY_URL}" ]
then
  echo "Skipping re-tagging; same URL used for v1 and v2"
  read -rsp $'Swap v1 and v2 registries and then press any key to continue...\n' -n1 key
else
  # re-tag images
  for i in ${FULL_IMAGE_LIST}
  do
    echo -n "Re-tagging '${V1_REGISTRY_URL}/${i}' as '${V2_REGISTRY_URL}/${i}'..."
    docker tag -f ${V1_REGISTRY_URL}/${i} ${V2_REGISTRY_URL}/${i}
    echo -e "done\n"
  done
fi

# verify V2_REGISTRY_URL is reporting as a v2 registry
if $(curl -Is https://${V2_REGISTRY_URL}/v2/ | grep ^'Docker-Distribution-Api-Version: registry/2.0' > /dev/null 2>&1)
then
  echo "Verified v2 registry (${V2_REGISTRY_URL}) is available"
else
  echo "Error: v2 registry (${V2_REGISTRY_URL}) is not available"
fi

# perform a docker login to the v2 registry
echo "Please login for ${V2_REGISTRY_URL}:"
docker login ${V2_REGISTRY_URL}

# push images to v2 registry
for i in ${FULL_IMAGE_LIST}
do
  docker push ${V2_REGISTRY_URL}/${i}
done

echo -e "\nMigration from v1 to v2 complete!"
