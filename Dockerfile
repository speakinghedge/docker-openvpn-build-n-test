FROM debian:8.5

RUN apt-get update
RUN apt-get install -y build-essential autoconf automake cmake
RUN apt-get install -y net-tools
RUN apt-get install -y git nano
RUN apt-get install -y libtool
RUN apt-get install -y libsnappy-dev liblzo2-dev libpam0g-dev libssl-dev
RUN apt-get install -y easy-rsa

WORKDIR /openvpn