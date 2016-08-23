# preface

This is raw and was created to ease the setup during development (or in other words: to support my laziness). There is no extensive error checking and you may (or may not) shoot you in the foot by running these scripts...

# configuration

All configuration is located in *env.sh* - the variables should be self explanatory.


# openvpn build container

To start a docker container shipping everything required to build openvpn just run:

```
> build-with-docker.sh
```

The script updates the submodule (https://github.com/OpenVPN/openvpn.git), builds the docker container and drops you to a shell inside of the container.
From here you can configure and build openvpn as usual...

```
root@openvpn-builder:/openvpn# autoreconf -i
...
root@openvpn-builder:/openvpn# ./configure
...
root@openvpn-builder:/openvpn# make
```

# testbed

The testbed consists of one server and a number of clients (default: 2, see CLIENT_INSTANCES).

```
   172.16.1.2/16                 172.1.2.1/24             172.1.2.254/24
 +--------------------+        +---------------+        +----------------+
 | openvpn-client-000 |--------|openvpn-testnet|--------| openvpn-server |
 +--------------------+        +---------------+        +----------------+
                                 |(docker bridge)       VPN_IPv4: 10.8.0.1
                                 |
   172.16.1.3/16                 |
 +--------------------+          |
 | openvpn-client-001 |----------+
 +--------------------+        

  ... (0..CLIENT_INSTANCES-1)
```

The testbed management script is named *setup-testbed.sh*. Containers managed by this script are identified using the container names and not the container IDs. So be careful in environments with containers named according the naming scheme applied here but not created by this script...

The server and the clients are started using a generated script. If you need to add actions taking place before/after running the server or clients this would be the right place to drop your lines (see functions *server_start()/clients_start()*).

You can clean up the environment by using the option *-r*. This kills and deletes all started containers and removes the generated ca, keys, and certs.

## server

To start a server in a docker container attached to the console run

```
>./setup-testbed.sh -d -S
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! openvpn status log:  /tmp/openvpn-status.log
!!! openvpn server log:  /tmp/openvpn.log
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
root@openvpn-server:/openvpn# ps -A
  PID TTY          TIME CMD
    1 ?        00:00:00 bash
    6 ?        00:00:00 bash
   12 ?        00:00:00 openvpn
   13 ?        00:00:00 bash
   16 ?        00:00:00 ps
```

The script updates the submodule easy-rsa (https://github.com/OpenVPN/easy-rsa.git), creates the requited ca, keys and certs and starts a container running one instance of openvpn server.

By omitting the option *-d* the server is started in detached mode so you need to run *docker attach \<instance name\>* to get connected to the servers console.

The configuration for the server is generated using the template in *config/server.template*.

If there is a file in *config/* named *\<SERVER_BASE_NAME\>.conf* this file is used instead of the template.

The following variables are replaced (if found) while creating the instance configuration file:


NAME                     | assoc. config option | source
|---|---|---|
@SERVER_CA_CERT@         | ca                   | generated
@SERVER_CERT@            | cert                 | generated
@SERVER_KEY@             | key                  | generated
@SERVER_DH_PARAM@        | dh                   | generated
@SERVER_SUBNET_ADDRESS@  | server - ip address  | env.sh:VPN_SUBNET_ADDRESS
@SERVER_SUBNET_NETMASK@  | server - netmask     | env.sh:VPN_SUBNET_NETMASK

**NOTE:** Currently tls-auth is disabled by default.

These changes are applied on files from both sources (template or user supplied configuration file).

The *log* and *status* options are only changed if the template based configuration is used.
Log points to */tmp/openvpn.log* and status to */tmp/openvpn-status.log*.

Use the option *-s* top stop resp. *-k* to kill the server.

## client

To start the clients run

```
>./setup-testbed.sh -C
```

Clients are always created in detached mode, so you need to run *docker attach openvpn-client-XXX* to get a console.

After the client has connected to the server (see log in */tmp/openvpn.log*) you should get the usual tun0-interface using an address within the configured subnet (*default: 10.8.0.0*):
```
root@openvpn-client-000:/openvpn# ip a s
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default 
    ...
4: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UNKNOWN group default qlen 100
    link/none 
    inet 10.8.0.14 peer 10.8.0.13/32 scope global tun0
       valid_lft forever preferred_lft forever
9: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 02:42:ac:01:02:02 brd ff:ff:ff:ff:ff:ff
    inet 172.1.2.2/24 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::42:acff:fe01:202/64 scope link 
       valid_lft forever preferred_lft forever
```

The configuration for the clients is generated using the template in *config/client.template*.

If there is a file in *config/* named *\<CLIENT_BASE_NAME\>-\<XYZ\>.conf* (e.g. openvpn-client-042.conf) this file is used instead of the template.

The following variables are replaced (if found) while creating the instance configuration file:


NAME                     | assoc. config option | source
|---|---|---|
@CLIENT_CA_CERT@         | ca                   | generated
@CLIENT_CERT@            | cert                 | generated
@CLIENT_KEY@             | key                  | generated

**NOTE:** Currently tls-auth is disabled by default.

These changes are applied on files from both sources (template or user supplied configuration file).

The *log* option is only changed if the template based configuration is used and points to */tmp/openvpn.log*.

Use the option *-c* to stop all clients.

