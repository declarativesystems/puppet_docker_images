# Puppet Docker Images
Docker images containing Puppet Enterprise Puppet Master

# What is this?
A collection of scripts to assemble and create Docker images with a
pre-installed Puppet Enterprise Puppet master.

# Why would I want to do that?
I've been doing testing with [Beaker](https://github.com/puppetlabs/beaker/)
recently and found myself needing to install Puppet Enterprise each time I
ran my tests which took several minutes and generated lots of network traffic.

Switching to a Docker image with the Puppet Master built-in lets me run my
tests in a fraction of the time and also lets me distribute the container to
others easily using the Docker Hub

# Building
```shell
./build_image.rb --pe-version 2015.2.1 --tag-version VERSION_NUMBER [--hostname HOSTNAME]
```
Build a new docker image for a given Puppet Enterprise version and tag the 
resulting image with a version number.  If hostname is specified your 
installation will be tailored to include it and the image name will include 
`private`.

# Running

## Beaker
Reference the image name and/or repository you have produced in the nodeset
file, eg:

```
HOSTS:
  pe-puppet.localdomain:
    roles:
      - "agent"
      - "master"
    platform: "el-7-x86_64"
    image: "geoffwilliams/pe2015-2-1_centos-7_aio-master_public:1"
    hypervisor : "docker"
```

## Basic
```shell
docker run -d -P --privileged --name CONTAINER_NAME \
  --volume /sys/fs/cgroup:/sys/fs/cgroup --hostname pe-puppet.localdomain
```
Start a Docker container with the hostname it was installed for.  Note, data
will be stored inside the container.  This is good for testing but could lead
to dataloss in more complex scenarios - see #Advanced for more info.  Also note
that there is no SSH server available unless you have added one yourself.

## Advanced
```shell
docker run -d --privileged \
  --name CONTAINER_NAME \
  --volume /sys/fs/cgroup:/sys/fs/cgroup \
  --volume /etc/puppetlabs \
  --volume /var/log \
  --volume /opt/puppetlabs/server/data \
  --hostname HOSTNAME \
  --restart always \
  IMAGE_NAME
pipework br0 CONTAINER_NAME udhcpc
```
Start a docker container that restores itself on reboot, set a hostname and use
[pipework](https://github.com/jpetazzo/pipework) to connect the container 
directly to a pre-existing bridged network adaptor `br0`.  Uses `udhcpc` on the
docker *host* machine to obtain an IP address.  Its also possible to specify an
IP address and CIDR mask here instead.

# Pushing to local repository
```shell
docker tag repo:port/IMAGE_NAME
docker push repo:port/IMAGE_NAME
```

# Pusing to Docker Hub
```shell
docker push IMAGE_NAME
```

# How does the build work?
1.  A customised Dockerfile will be created by munging the requested Puppet
    Enterprise version number into the Dockerfile ERB template
2.  A centos image will be created and configured to run with systemd and SSH
3.  The Puppet Enterprise tarball will be downloaded into the image
4.  A container will be created from the image in privileged mode (needed for
    systemd)
5.  The script will SSH into the container, run the puppet enterprise installer
    and then remove the SSH keys.  The Puppet Enterprise installer will be run
     using the `all-in-one.answers.txt` file with the hostname set to whatever
    the script was called with (defaults to `pe-puppet.localdomain`)
6.  The image will be committed and tagged with the name in the bash script

# Security
This image is primarily targetted at throw-away test environments so security
isn't a huge concern at the moment.  With that said, there are some security
settings to be aware of:
* SSH is disabled in the final image by removing the SSH daemon's 
  public/private keypairs
* The `root` password is `root`
* The console `admin` password is `aaaaaaaa`, this can be changed through the
  GUI
* Other puppet passwords are generated randomly on a per-image basis
* You should build and host your own image if you would like to choose a more
  suitable hostname and ensure that your passwords are unique

# Ruby script? What about Fig or Docker compose...
I did briefly look at these after a colleague recommended them but I ended up
throwing them in the too-hard basket- at least for the moment.

# Troubleshooting
* Puppet Enterprise needs about 3-6GB RAM to work without crashing.  If your
  running on a mac or windows, you will need to ensure your docker-machine
  (formerly boot2docker) has lots of memory available or your container might
  run out

# Todo
* Figure out how to reduce Puppet memory usage and publish a new image.  This
  is needed to allow this code to work nicely with CI systems such as
  (travis-ci)[http://travis-ci.org/]

# What is the status of this code
This code is experimental and is in no way supported by Puppet Labs.  Its
shamefully basic at the moment as I've written just enough to let me generate
an image and publish it to Docker Hub.  Pull Requests accepted.

# Is there a ready-to-use image?
Sure, have a look at https://hub.docker.com/r/geoffwilliams.  Images seem to do the job for testing but aren't much use as real puppet masters yet.  Need to improve security and figure out what to do with data volumes first.
