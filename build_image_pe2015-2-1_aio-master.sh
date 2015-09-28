#!/bin/bash
set -e

# Use user-supplied hostname if set
if [ "$1" == "" ] ; then
    export PUPPET_HOSTNAME="pe-puppet.localdomain"
    IMG_TYPE="public"
else
    export PUPPET_HOSTNAME="$1"
    IMG_TYPE="private"
fi


BASENAME="pe2015-2-1_centos-7"
FINALNAME="${BASENAME}_aio-master_${IMG_TYPE}"
PE_MEDIA="puppet-enterprise-2015.2.1-el-7-x86_64"
DOCKER_HUB_NAME="geoffwilliams/${FINALNAME}:v0"

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

# address of the docker-machine VM (boot2docker) or just good 'ol localhost on
# real computers
DM_IP=$(docker-machine ip default 2>/dev/null|| echo localhost)

# find the ssh port...
SSH_PORT=$(docker inspect -f '{{ index .NetworkSettings.Ports "22/tcp" 0 "HostPort" }}' $FINALNAME)


echo docker-machine IP $DM_IP, ssh port $SSH_PORT
sleep 5
scp -P $SSH_PORT ./answers/all-in-one.answers.txt "root@${DM_IP}:answers.txt"
echo "answers file uploaded"
ssh -p $SSH_PORT root@$DM_IP "cd /root/$PE_MEDIA && export PUPPET_HOSTNAME=${PUPPET_HOSTNAME} && ./puppet-enterprise-installer -a /root/answers.txt"

docker commit $FINALNAME $DOCKER_HUB_NAME
