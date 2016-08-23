#!/bin/bash

HOME_PATH=$(dirname $(realpath -s $0))

# path to the open-vpn-sources on the host (default: submodle path)
OPENVPN_SOURCE_PATH="${HOME_PATH}/openvpn"
OPENVPN_SUBMODULE_PATH="${OPENVPN_SOURCE_PATH}"

# path of the openvpn binary in the container (default: binary build from the sources in the submodule)
OPENVPN_CONTAINER_BINARY_PATH="/openvpn/src/openvpn/openvpn"

# temp dir used on the host
SYSTEM_TEMP_DIR="/tmp/"

########################
# easy-rsa config
# 
########################
# path to easy-rsa (default: submodle path)
EASY_RSA_SOURCE_PATH="${HOME_PATH}/easy-rsa"
EASY_RSA_SUBMODULE_PATH="${EASY_RSA_SOURCE_PATH}"
EASY_RSA_KEY_DIR="${EASY_RSA_SOURCE_PATH}/keys"
EASY_RSA_BINARY_PATH="${EASY_RSA_SOURCE_PATH}/easyrsa3/easyrsa"
EASY_RSA_OPENSSL_CONFIG="${EASY_RSA_SOURCE_PATH}/easyrsa3/openssl-1.0.cnf"
EASY_RSA_X509_TYPE_SOURCE="${EASY_RSA_SOURCE_PATH}/easyrsa3/x509-types"
EASY_RSA_KEY_SIZE=1024
OPENSSL_BINARY="openssl"

########################
# server config
########################
# where to look for server.template or instance specific config files
SERVER_CONFIG_DIR="${HOME_PATH}/config"
# used to name instance container and host
SERVER_BASE_NAME="openvpn-server"
SERVER_SUBNET_ADDRESS="10.8.0.0"
SERVER_SUBNET_NETMASK="255.255.255.0"

########################
# client config
########################
# clients per server
CLIENT_INSTANCES=2
CLIENT_CONFIG_DIR="${HOME_PATH}/config"
CLIENT_BASE_NAME="openvpn-client"

if [ $CLIENT_INSTANCES -gt 251 ] ; then
	echo "CLIENT_INSTANCES bigger then 251 - abort."
	exit 1
fi


########################
# builder 
########################
BUILDER_CONTAINER_NAME="openvpn-builder"

########################
# docker specific 
########################
DOCKER_IMAGE_NAME="openvpn-build-env"
DOCKER_NETWORK_NAME="openvpn-testnet"
DOCKER_NETWORK_IPV4_SUBNET_ADDRESS="172.1.2.0"
DOCKER_NETWORK_IPV4_SERVER_ADDRESS="172.1.2.254"
DOCKER_NETWORK_IPV4_SUBNET_NETMASK="24"

docker_client_get_address_ipv4()
{
	if [ $# -lt 1 ] ; then
		echo "missing parameter client instance index"
		exit 1
	fi

	# .1 is take by the docker bridge
	addr=$(( $1 + 2 ))

	if [ $addr -lt 1 -o $addr -gt 253 ] ; then
		echo "invalid client index. must be [0,251] - got $addr"
		exit 1
	fi

	echo $(echo $DOCKER_NETWORK_IPV4_SUBNET_ADDRESS | sed 's|.0$|'."$addr"'|g')
}

docker_prepare()
{
	if [ $(docker images  | grep -c ${DOCKER_IMAGE_NAME}) -lt 1 ] ; then
		docker build -t ${DOCKER_IMAGE_NAME} ${HOME_PATH}
	fi
}

docker_container_is_running()
{
	if [ $# -lt 1 ] ; then
		echo "missing parameter docker container id/name"
		exit 1
	fi

	echo $(docker ps -f status=created -f status=restarting -f status=running -f status=paused | grep -c "$1")
}

docker_container_is_present()
{
	if [ $# -lt 1 ] ; then
		echo "missing parameter docker container id/name"
		exit 1
	fi

	echo $(docker ps -a | grep -c "$1")
}

########################
# easy rsa 3 
########################
easy_rsa_clean()
{
	rm -rf $EASY_RSA_KEY_DIR
}

easy_rsa_prepare()
{
	git submodule update ${EASY_RSA_SUBMODULE_PATH}

	if [ ! -d $EASY_RSA_KEY_DIR ] ; then
		echo "*** init pki"
		export EASYRSA_SSL_CONF="$EASY_RSA_OPENSSL_CONFIG"
		${EASY_RSA_BINARY_PATH} --pki-dir="${EASY_RSA_KEY_DIR}" init-pki
	fi

	# fix missing x509-types in EASY_RSA_KEY_DIR
	# if the file is not present, easyrsa tries to find the files via checking $(pwd)/x509-types - but if you run easyrsa from somewhere else...
	# (this is a documented but not expected behavior)
	if [ ! -d "${EASY_RSA_KEY_DIR}"/x509-types ] ; then
		ln -s "${EASY_RSA_X509_TYPE_SOURCE}" "${EASY_RSA_KEY_DIR}"/x509-types
	fi

}

easy_rsa_build_ca()
{
	if [ ! -f ${EASY_RSA_KEY_DIR}/ca.crt ] ; then
		echo "*** create ca certificate..."
		export EASYRSA_SSL_CONF="$EASY_RSA_OPENSSL_CONFIG"
		${EASY_RSA_BINARY_PATH} --batch --pki-dir="${EASY_RSA_KEY_DIR}" build-ca nopass
	fi
}

easy_rsa_server_prepare()
{
	if [ $# -lt 1 ] ; then
		echo "missing parameter server-name. abort."
		exit 1
	fi

	SRV_NAME="$1"

	set -e 

	easy_rsa_build_ca

	# create dh parameters for server
	export OPENSSL=${OPENSSL_BINARY}
	if [ ! -f ${EASY_RSA_KEY_DIR}/dh${EASY_RSA_KEY_SIZE}.pem ] ; then
		echo "*** create dh parameters for ${SRV_NAME}..."
		export EASYRSA_SSL_CONF="$EASY_RSA_OPENSSL_CONFIG"
		${EASY_RSA_BINARY_PATH} --batch --pki-dir="${EASY_RSA_KEY_DIR}" --keysize=${EASY_RSA_KEY_SIZE} gen-dh
		cp ${EASY_RSA_KEY_DIR}/dh.pem ${EASY_RSA_KEY_DIR}/dh${EASY_RSA_KEY_SIZE}.pem
	fi

	# create server key and cert
	if [ ! -f ${EASY_RSA_KEY_DIR}/issued/${SRV_NAME}.crt -o ! -f ${EASY_RSA_KEY_DIR}/private/${SRV_NAME}.key ] ; then
		echo "*** create key/crt for ${SRV_NAME}..."
		export EASYRSA_SSL_CONF="$EASY_RSA_OPENSSL_CONFIG"
		${EASY_RSA_BINARY_PATH} --batch --pki-dir="${EASY_RSA_KEY_DIR}" --req-cn=${SRV_NAME} --keysize=${EASY_RSA_KEY_SIZE} build-server-full ${SRV_NAME} ${SRV_NAME} nopass
	fi

	set +e 
}

easy_rsa_client_prepare()
{
	if [ $# -lt 1 ] ; then
		echo "missing parameter client-name. abort."
		exit 1
	fi

	CLIENT_NAME="$1"

	set -e

	easy_rsa_build_ca

	if [ ! -f ${EASY_RSA_KEY_DIR}/issued/${CLIENT_NAME}.crt -o ! -f ${EASY_RSA_KEY_DIR}/private/${CLIENT_NAME}.key ] ; then
		echo "*** create key/crt for ${CLIENT_NAME}..."
		export EASYRSA_SSL_CONF="$EASY_RSA_OPENSSL_CONFIG"
		${EASY_RSA_BINARY_PATH} --batch --pki-dir="${EASY_RSA_KEY_DIR}" --req-cn=${CLIENT_NAME} --keysize=${EASY_RSA_KEY_SIZE} build-client-full ${CLIENT_NAME} nopass
	fi

	set +e
}