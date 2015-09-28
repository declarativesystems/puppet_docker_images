#!/bin/bash
set -e

# Use user-supplied hostname if set
if [ "$1" == "" ] ; then
    export PUPPET_HOSTNAME="pe-puppet.localdomain"
else
    export PUPPET_HOSTNAME="$1"
fi


BASENAME="pe2015-2-1_centos-7"
FINALNAME="${BASENAME}_aio-master"
PE_MEDIA="puppet-enterprise-2015.2.1-el-7-x86_64"
DOCKER_HUB_NAME="geoffwilliams/${BASENAME}_aio-master:v0"

docker build --rm -t $BASENAME .

docker run \
  --publish-all \
  --detach=true \
  --volume /sys/fs/cgroup:/sys/fs/cgroup \
  --privileged \
  --hostname $PUPPET_HOSTNAME \
  --env container=docker \
  --name $FINALNAME \
  $BASENAME

# address of the docker-machine VM (boot2docker)
DM_IP=$(docker-machine ip default)

# find the ssh port...
SSH_PORT=$(docker inspect -f '{{ index .NetworkSettings.Ports "22/tcp" 0 "HostPort" }}' $FINALNAME)

echo docker-machine IP $DM_IP, ssh port $SSH_PORT
scp -p $SSH_PORT root@$DM_IP "./answers/all-in-one.answers.txt" "/root/all-in-one-answers.txt"
ssh -p $SSH_PORT root@$DM_IP "cd /root/$PE_MEDIA && ./puppet-enterprise-installer -a /root/all-in-one.answers.txt"

docker commit $FINALNAME $DOCKER_HUB_NAME
