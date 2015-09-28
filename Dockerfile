FROM centos:7
MAINTAINER Geoff Williams <geoff.williams@puppetlabs.com>
ENV container docker

# puppet needs full systemd
RUN yum -y swap -- remove systemd-container systemd-container-libs -- install systemd systemd-libs \
  yum -y update; yum clean all; \
  (cd /lib/systemd/system/sysinit.target.wants/; for i in *; do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i; done); \
  rm -f /lib/systemd/system/multi-user.target.wants/*;\
  rm -f /etc/systemd/system/*.wants/*;\
  rm -f /lib/systemd/system/local-fs.target.wants/*; \
  rm -f /lib/systemd/system/sockets.target.wants/*udev*; \
  rm -f /lib/systemd/system/sockets.target.wants/*initctl*; \
  rm -f /lib/systemd/system/basic.target.wants/*;\
  rm -f /lib/systemd/system/anaconda.target.wants/*;
  VOLUME [ "/sys/fs/cgroup" ]

# ssh setup
RUN yum install -y sudo openssh-server openssh-clients curl ntpdate
RUN ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key
RUN ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key
RUN mkdir -p /var/run/sshd
RUN echo root:root | chpasswd
RUN sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# misc packages we need fo various stuff
RUN yum -y install git cronie wget

# firewall off, ssh on
RUN systemctl disable firewalld
RUN systemctl enable sshd
#RUN systemctl start sshd

# download and unpack PE
RUN wget -O /root/puppet-enterprise-2015.2.0-el-7-x86_64.tar.gz "https://pm.puppetlabs.com/cgi-bin/download.cgi?dist=el&rel=7&arch=x86_64&ver=latest" && \
  cd /root/ && tar zxvf puppet-enterprise-2015.2.0-el-7-x86_64.tar.gz && \
  rm puppet-enterprise-2015.2.0-el-7-x86_64.tar.gz

# fix locale and paths
RUN echo 'export LC_ALL="en_US.UTF-8"' >> ~/.bashrc && \
  echo 'export PATH=/opt/puppetlabs/puppet/bin/:${PATH}' >> ~/.bashrc


EXPOSE 22
EXPOSE 8140
EXPOSE 443
EXPOSE 61616

CMD ["/usr/sbin/init"]

# !!!CANNOT!!! RUN THE INSTALLER UNTIL WE HAVE RELOADED IN PRIVILEGED MODE
#&& ./puppet-enterprise-installer -a answers/all-in-one.answers.txt
