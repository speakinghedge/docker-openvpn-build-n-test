#!/bin/bash
source ./env.sh

git submodule update --init ${OPENVPN_SUBMODULE_PATH}

docker_prepare

if [ $(docker_container_is_running ${BUILDER_CONTAINER_NAME}) -gt 0 ] ; then
	echo "container '${BUILDER_CONTAINER_NAME}' already running. abort."
	exit 1
fi

if [ $(docker_container_is_present ${BUILDER_CONTAINER_NAME}) -gt 0 ] ; then
	echo "container '${BUILDER_CONTAINER_NAME}' present but not running. remove..."
	docker rm ${BUILDER_CONTAINER_NAME}
fi

cid="$(docker run -tid -h ${BUILDER_CONTAINER_NAME} -v ${OPENVPN_SOURCE_PATH}:/openvpn/ --name=${BUILDER_CONTAINER_NAME} ${DOCKER_IMAGE_NAME})"
trap "docker rm -fv $cid" EXIT
docker attach $cid
