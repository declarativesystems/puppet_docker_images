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

# How do I use this?
Edit the bash script and tweak any variables as required (or make a new copy)
then run the script.  The following steps will then take place:

1.  A centos image will be created and configured to run with systemd and ssh
2.  The Puppet Enterprise tarball will be downloaded into the image.  Change
    the Dockerfile to alter the Puppet Enterprise version
3.  A container will be created from the image in privileged mode (needed for
    systemd)
4.  The bash script will ssh into the container.  At this point you will be
    asked to add the new host to your known hosts and you will then be asked
    for the `root` password which is just `root`
5.  Once logged in, the Puppet Enterprise installer will be run using the
    `all-in-one.answers.txt` file with its default settings
6.  The image will be committed and tagged with the name in the bash script

Once the process has completed, the new image can be pushed for the Docker Hub.

# Isn't this really insecure
Yes!  The default passwords are unchanged, etc.  The reason for this is that
this isn't a system intended for production or even development use - its
intended to be run from a CI system and then destroyed.  There are no agents
connecting to it or anything like that.

...Of course, that's not to say you couldn't improve the security and connect
some ;^)

# Bash script? Yuk!  What about Fig or Docker compose...
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
