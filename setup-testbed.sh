#!/bin/bash
source ./env.sh

############################################################################################################

usage()
{

## Usage: setup-testbed [OPTION]... 
## Create openvpn test setup.
## 
## Options:
##   -S, --server               start server (create network if required)
##   -C, --client               start clients  (create network if required)
##   -a, --stop-all             stop all running clients and servers, destroy network
##   -c, --stop-clients         stop and destroy all clients (uses docker kill + rm)
##   -s, --stop-server          stop and destroy server (uses docker stop)
##   -k, --kill-server          kill and destroy server (uses docker kill + rm)
##   -r, --remove-all           stop all containers and remove all created files (keys, config,...)
##   -d, --do-not-daemonize     don't daemonize server instance
##   -D, --daemonize            daemonize server instance (default)
##   -h, --help                 show this help
## 

grep -e ^"## " $0 | sed 's|## ||g'

}

main() 
{
	if [ ! -d $TEST_BASE_DIR ] ; then
		mkdir $TEST_BASE_DIR
	fi

	easy_rsa_prepare

	daemonize=1

	if [ $# -lt 1 ] ; then
		echo "missing action"
		echo
		usage
		exit 1
	fi

	while [[ $# -gt 0 ]] ; do
		case $1 in
			--server|-S)
				network_setup
				server_start $SERVER_BASE_NAME $daemonize 
				;;
			--client|-C)
				network_setup
				clients_start $daemonize
				;;
			--do-not-daemonize|-d)
				daemonize=0
				;;
			--daemonize|-D)
				daemonize=1
				;;
			--stop-clients|-c)
				clients_stop
				;;
			--stop-server|-s)
				server_stop
				;;
			--kill-server|-k)
				server_kill
				;;
			--stop-all|-a)
				stop_containers
				network_destroy
				;;
			--remove-all|-r)
				stop_containers
				network_destroy
				easy_rsa_clean
				clean
				;;
			--help|-h)
				usage
				exit 0
				;;
			*)
				echo "unknown option $1"
				echo
				usage
				exit 1
		esac
		shift
	done

	exit $?
}

############################################################################################################

clean()
{
	rm -rf ${SYSTEM_TEMP_DIR}/${CLIENT_BASE_NAME-}* ${SYSTEM_TEMP_DIR}/${SERVER_BASE_NAME}*
}

stop_containers()
{
	clients_stop
	server_stop
}

############################################################################################################
### network
############################################################################################################

network_setup()
{
	if [ $(docker network ls  | grep -c ${DOCKER_NETWORK_NAME}) -ne 1 ] ; then
		echo "create network ${DOCKER_NETWORK_NAME}"
		docker network create --subnet=${DOCKER_NETWORK_IPV4_SUBNET_ADDRESS}/${DOCKER_NETWORK_IPV4_SUBNET_NETMASK} ${DOCKER_NETWORK_NAME}
	fi
}

network_destroy()
{
	if [ $(docker network ls  | grep -c ${DOCKER_NETWORK_NAME}) -eq 1 ] ; then
		echo "destroy network ${DOCKER_NETWORK_NAME}"
		docker network rm ${DOCKER_NETWORK_NAME}
	fi
}

############################################################################################################
### server
############################################################################################################

server_start()
{
	if [ $# -lt 2 ] ; then
		echo "expect two parameters: <instance-name> <daemonize>"
		exit 1
	fi

	instance_name=${1}
	daemonize=1
	if [ ${2} -lt 1 ] ; then
		daemonize=0
	fi

	if [ $(docker_container_is_running ${instance_name}) -gt 0 ] ; then
		echo "server container '${instance_name}' already running. abort."
		exit 1
	fi

	if [ $(docker_container_is_present ${instance_name}) -gt 0 ] ; then
		echo "server container '${instance_name}' present but inactive - remove..."
		docker rm -fv $instance_name
	fi

	tmp_dir=$(mktemp -p ${SYSTEM_TEMP_DIR} -t -d ${instance_name}.XXXXXXXXX)

	easy_rsa_server_prepare $SERVER_BASE_NAME
	
	cp ${EASY_RSA_KEY_DIR}/ca.crt ${tmp_dir}/ca.crt
	cp ${EASY_RSA_KEY_DIR}/issued/${SRV_NAME}.crt ${tmp_dir}/${SRV_NAME}.crt
	cp ${EASY_RSA_KEY_DIR}/private/${SRV_NAME}.key ${tmp_dir}/${SRV_NAME}.key
	chmod 600 ${tmp_dir}/${SRV_NAME}.key
	cp ${EASY_RSA_KEY_DIR}/dh${EASY_RSA_KEY_SIZE}.pem ${tmp_dir}/dh${EASY_RSA_KEY_SIZE}.pem

	# use instance specific config...
	if [ -f ${SERVER_CONFIG_DIR}/${instance_name}.conf ] ; then
		cp ${SERVER_CONFIG_DIR}/${instance_name}.conf ${tmp_dir}/
	else
		# ...or generate config from template
		cp ${SERVER_CONFIG_DIR}/server.template ${tmp_dir}/${instance_name}.conf

		# enable status and logging to /tmp/...
		sed -i 's|;*log\s\+openvpn.log|log /tmp/openvpn.log|g' ${tmp_dir}/${instance_name}.conf
		sed -i 's|;*status openvpn-status.log|status /tmp/openvpn-status.log|g' ${tmp_dir}/${instance_name}.conf
	fi

	# replace template vars		
	sed -i 's|\@SERVER_CA_CERT\@|'"${tmp_dir}/ca.crt"'|g' ${tmp_dir}/${instance_name}.conf
	sed -i 's|@SERVER_CERT@|'"${tmp_dir}/${SRV_NAME}.crt"'|g' ${tmp_dir}/${instance_name}.conf
	sed -i 's|@SERVER_KEY@|'"${tmp_dir}/${SRV_NAME}.key"'|g' ${tmp_dir}/${instance_name}.conf
	sed -i 's|@SERVER_DH_PARAM@|'"${tmp_dir}/dh${EASY_RSA_KEY_SIZE}.pem"'|g' ${tmp_dir}/${instance_name}.conf
	sed -i 's|@SERVER_SUBNET_ADDRESS@|'${SERVER_SUBNET_ADDRESS}'|g' ${tmp_dir}/${instance_name}.conf
	sed -i 's|@SERVER_SUBNET_NETMASK@|'${SERVER_SUBNET_NETMASK}'|g' ${tmp_dir}/${instance_name}.conf

	# disable tls-auth (would require one additional build-step...)
	# TODO: enable me ASAP.
	sed -i 's/^\s*tls-auth/;tls-auth/g' ${tmp_dir}/${instance_name}.conf

	cat << EOF > ${tmp_dir}/start.sh
#!/bin/bash
######################################################################################################
# in case someone would like to add some stuff to be executed before/after running openvpn-server...
# this is the right place.
######################################################################################################
${OPENVPN_CONTAINER_BINARY_PATH} --daemon --config ${tmp_dir}/${instance_name}.conf
/bin/bash
EOF
	
	chmod +x ${tmp_dir}/start.sh
	
	if [ $daemonize -ne 1 ] ; then
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		echo "!!! openvpn status log:  /tmp/openvpn-status.log"
		echo "!!! openvpn server log:  /tmp/openvpn.log"
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		cid="$(docker run -tid -v ${OPENVPN_SOURCE_PATH}:/openvpn/ -v ${tmp_dir}:${tmp_dir} --net=${DOCKER_NETWORK_NAME} --ip ${DOCKER_NETWORK_IPV4_SERVER_ADDRESS} -h ${instance_name} --name ${instance_name} --privileged ${DOCKER_IMAGE_NAME})"
		trap "docker rm -fv $cid" EXIT
		#docker attach $cid
		docker exec -it $cid /bin/bash ${tmp_dir}/start.sh
	else
		# ${SRV_TEST_DIR}/start.sh
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		echo "!!! started detached - remember to stop and remove the server"
		echo "!!! openvpn status log:  /tmp/openvpn-status.log"
		echo "!!! openvpn server log:  /tmp/openvpn.log"
		echo "!!!"
		echo "!!! attach to container by running: docker attach ${instance_name}"
		echo "!!!"
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		
		docker run -tid -v ${OPENVPN_SOURCE_PATH}:/openvpn/ -v ${tmp_dir}:${tmp_dir} --net=${DOCKER_NETWORK_NAME} --ip ${DOCKER_NETWORK_IPV4_SERVER_ADDRESS} -h ${instance_name} --name ${instance_name} --privileged ${DOCKER_IMAGE_NAME} ${tmp_dir}/start.sh
	fi
}

server_stop()
{
	if [ $(docker ps | grep -c $SERVER_BASE_NAME) -gt 0 ] ; then
		echo "stop server container $SERVER_BASE_NAME"
		docker stop $SERVER_BASE_NAME 1>/dev/null
	fi
	if [ $(docker ps -a | grep -c $SERVER_BASE_NAME) -gt 0 ] ; then
		docker rm $SERVER_BASE_NAME 1>/dev/null
	fi
}

server_kill()
{
	if [ $(docker ps | grep -c $SERVER_BASE_NAME) -gt 0 ] ; then
		echo "kill server container $SERVER_BASE_NAME"
		docker kill $SERVER_BASE_NAME 1>/dev/null
		docker rm $SERVER_BASE_NAME 1>/dev/null
	fi
}

############################################################################################################
### clients
############################################################################################################

clients_start()
{
	for i in $(seq 0 $(( $CLIENT_INSTANCES - 1 ))) ; do

		instance_name=$(printf "%s-%03d" $CLIENT_BASE_NAME $i)
		instance_ipv4_address=$(docker_client_get_address_ipv4 $i)

		if [ $(docker_container_is_running ${instance_name}) -gt 0 ] ; then
			echo "client container '${instance_name}' already running. skipping creation."
			continue
		fi

		if [ $(docker_container_is_present ${instance_name}) -gt 0 ] ; then
			echo "client container '${instance_name}' present but inactive - remove..."
			docker rm -fv $instance_name
		fi

		easy_rsa_client_prepare ${instance_name}

		tmp_dir=$(mktemp -p ${SYSTEM_TEMP_DIR} -t -d ${instance_name}.XXXXXXXXX)
	
		cp ${EASY_RSA_KEY_DIR}/ca.crt ${tmp_dir}/ca.crt
		cp ${EASY_RSA_KEY_DIR}/issued/${instance_name}.crt ${tmp_dir}/${instance_name}.crt
		cp ${EASY_RSA_KEY_DIR}/private/${instance_name}.key ${tmp_dir}/${instance_name}.key
		chmod 600 ${tmp_dir}/${instance_name}.key

		# use instance specific config...
		if [ -f ${CLIENT_CONFIG_DIR}/${instance_name}.conf ] ; then
			echo "use instance specific config for $instance_name"
			cp ${CLIENT_CONFIG_DIR}/${instance_name}.conf ${tmp_dir}/
		else
			# ...or generate config from template
			echo "generate configuration for $instance_name"
			cp ${CLIENT_CONFIG_DIR}/client.template ${tmp_dir}/${instance_name}.conf

			# enable logging to /tmp/openvpn.log
			if [ $(grep -c -e "^;+log" ${tmp_dir}/${instance_name}.conf ) -gt 0 ] ; then
				sed -i 's|;*log\s\+openvpn.log|log /tmp/openvpn.log|g' ${tmp_dir}/${instance_name}.conf
			else
				echo "log /tmp/openvpn.log" >> ${tmp_dir}/${instance_name}.conf
			fi
		fi

		sed -i 's|\@CLIENT_CA_CERT\@|'"${tmp_dir}/ca.crt"'|g' ${tmp_dir}/${instance_name}.conf
		sed -i 's|@CLIENT_CERT@|'"${tmp_dir}/${instance_name}.crt"'|g' ${tmp_dir}/${instance_name}.conf
		sed -i 's|@CLIENT_KEY@|'"${tmp_dir}/${instance_name}.key"'|g' ${tmp_dir}/${instance_name}.conf

		# disable tls-auth (would require one additional build-step...)
		# TODO: enable me ASAP.
		sed -i 's/^\s*tls-auth/;tls-auth/g' ${tmp_dir}/${instance_name}.conf

		sed -i 's|@CLIENT_REMOTE_SRV_ADDRESS@|'"${DOCKER_NETWORK_IPV4_SERVER_ADDRESS}"'|g' ${tmp_dir}/${instance_name}.conf

		# keepalive 20 70
		# redirect-gateway def1

		cat << EOF > ${tmp_dir}/start.sh
#!/bin/bash
######################################################################################################
# in case someone would like to add some stuff to be executed before/after running the openvpn-client...
# this is the right place.
######################################################################################################
${OPENVPN_CONTAINER_BINARY_PATH} --daemon --config ${tmp_dir}/${instance_name}.conf
/bin/bash
EOF
	
		chmod +x ${tmp_dir}/start.sh
		
		echo "!!! client ${instance_name} started detached - remember to stop and remove the client"
		echo "!!! openvpn client log:  /tmp/openvpn.log"
		echo "!!!"
		echo "!!! attach to container by running: docker attach ${instance_name}"
			
		docker run -tid -v ${OPENVPN_SOURCE_PATH}:/openvpn/ -v ${tmp_dir}:${tmp_dir} --net=${DOCKER_NETWORK_NAME} --ip ${instance_ipv4_address} -h ${instance_name} --name ${instance_name} --privileged ${DOCKER_IMAGE_NAME} ${tmp_dir}/start.sh

	done
}

clients_stop()
{
	for container_id in $(docker ps | grep ${CLIENT_BASE_NAME} | awk '{ print $1 }') ; do
		echo "kill and delete client container $container_id"
		docker kill $container_id 1>/dev/null
		docker rm $container_id 1>/dev/null
	done

	for container_id in $(docker ps -a | grep ${CLIENT_BASE_NAME} | awk '{ print $1 }') ; do
		echo "delete stopped client container $container_id"
		docker rm $container_id 1>/dev/null
	done
}

####################################################################################

main "$@"
