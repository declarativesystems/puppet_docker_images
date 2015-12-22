#!/usr/bin/env ruby

require 'getoptlong'
require 'net/scp'
require 'net/ssh'
require 'tmpdir'
require 'tempfile'
require 'erb'

def show_usage()
  puts <<-EOF
build_image --pe-version VERSION \
            --tag-version VERSION \
            [--hostname puppet.megacorp.com] \
            [--lowmem] \
            [--r10k-control GIT_URL] \
            [--dockerbuild]
Build a docker image with Puppet Enterprise installed and optionally
configure a specific hostname and/or low-memory settings

Options
-------
--pe-version VERSION
  Version of Puppet Enterprise to download and install, eg '2015.2.1'

--tag-version VERSION
  Numeric version number to tag the release with, eg 0

--hostname
  Hostname to install Puppet Enterprise for

--lowmem
  Configure Puppet Enterprise for a low-memory environment 

--r10k-control GIT_URL
  Bootstrap r10k using supplied URL or default to 
  https://github.com/GeoffWilliams/r10k-control.  Only supports R10K
  control repositories forked from the above URL and implementing a 
  bootstrap.sh install script

--dockerbuild
  Make this image support building docker images with puppet code.  This
  is a PE master running docker with access to the puppet-dockerbuild.rb 
  script

Examples
--------
build_image.rb --pe-version 2015.2.1 --tag-version 0
  Build a docker image for puppet enterprise 2015.2.1 using the default 
  settings and tag it as version 0

build_image.rb --pe-version 2015.2.1 --tag-version 0 --hostname puppet.megacorp.com
  Build a docker image for puppet enterprise 2015.2.1 configured for a hostname
  of puppet.megacorp.com and tag it as version 0
EOF
  exit 1
end

def parse_command_line()
  opts = GetoptLong.new(
    [ '--hostname',       GetoptLong::REQUIRED_ARGUMENT ],
    [ '--root-passwd',    GetoptLong::REQUIRED_ARGUMENT ],
    [ '--pe-version',     GetoptLong::REQUIRED_ARGUMENT ],
    [ '--tag-version',    GetoptLong::REQUIRED_ARGUMENT ],
    [ '--r10k-control',   GetoptLong::OPTIONAL_ARGUMENT ],
    [ '--lowmem',         GetoptLong::NO_ARGUMENT ],
    [ '--dockerbuild',    GetoptLong::NO_ARGUMENT ],
    [ '--help',           GetoptLong::NO_ARGUMENT ],
    [ '--debug',          GetoptLong::NO_ARGUMENT ],
  )

  opts.each do |opt,arg|
    case opt
    when '--help'
      show_usage()
    when '--hostname'
      @hostname = arg
    when '--lowmem'
      @lowmem = true
    when '--root-passwd'
      @root_passwd = arg
    when '--pe-version'
      @pe_version = arg
    when '--tag-version'
      @tag_version = arg
    when '--dockerbuild'
      @dockerbuild = true
    when '--r10k-control'
      @r10k_control = true
      if arg.nil?
        @r10k_control_url = "https://github.com/GeoffWilliams/r10k-control"
      else
        @r10k_control_url = arg
      end
    end
  end

  if @root_passwd.nil?
    @root_passwd = 'root'
  end

  if @pe_version.nil?
    puts "You must specify a PE version to use, eg 2015.2.1"
    show_usage()
  elsif @pe_version =~ /-/
    puts "PE versions are delimited by periods, not hypens - eg use 2015.2.1 not 2015-2-1"
    show_usage()
  end

  if @tag_version.nil? or ! @tag_version =~ /\d+/
    puts "You must specify a numeric tag for the image"
    show_usage()
  end

  if @hostname.nil?
    @hostname = "pe-puppet.localdomain"
  end
end

def scp(local_file,
        remote_file,
        ip:@dm_ip, 
        port:@ssh_port, 
        user:"root", 
        password:@root_passwd, 
        recursive:false)

  Net::SSH.start( ip, 
                  user, 
                  :password => password, 
                  :port     => port, 
                  :paranoid => Net::SSH::Verifiers::Null.new) do |ssh|

    ssh.scp.upload!(
      local_file,
      remote_file,
      :recursive => recursive,
    )
  end
end

def ssh(ip=@dm_ip, port=@ssh_port, user="root", password=@root_passwd, command)
  Net::SSH.start(ip, user, :password => password, :port => port, :paranoid => Net::SSH::Verifiers::Null.new) do |ssh|
    # capture all stderr and stdout output from a remote process
    ssh.exec!(command) do |ch, stream, line|
      puts line
    end
  end
end

def answer_template

  # passwords - hardcode for now
  # FIXME generate a random password here
  @password_pdb = "aaaaaaaa"
  @password_console = "aaaaaaaa"
  @shortname = @hostname.gsub(/\..+/, '')
  @dnsalt="puppet,#{@shortname},#{@hostname}"
  answerfile_erb = File.read("answers/all-in-one.answers.txt.erb")
  answerfile = ERB.new(answerfile_erb, nil, '-').result(binding)
  file = Tempfile.new("answers")
  file.write(answerfile)
  file.close

  return file
end

def setup_dockerbuild
  # download script and module to './build' directory, then SCP to host
  build_dir = "build"
  if ! Dir.exists?(build_dir) then
    Dir.mkdir(build_dir)
    Dir.chdir(build_dir)
    system("git clone https://github.com/garethr/garethr-docker")
    system("git clone https://github.com/GeoffWilliams/puppet-dockerbuild")
  else 
    Dir.chdir(build_dir)
  end
  scp("./garethr-docker", "/etc/puppetlabs/code/modules/docker", recursive: true)
  scp("./puppet-dockerbuild/puppet-dockerbuild.rb", "/usr/local/bin")
  
  # install gems and modules needed for script
  ssh("yum install -y ruby-devel e2fsprogs xfsprogs" )
  ssh("gem install excon docker-api")
  ssh("/opt/puppetlabs/puppet/bin/puppet module install puppetlabs/stdlib")
  ssh("/opt/puppetlabs/puppet/bin/puppet module install puppetlabs/apt")
  ssh("/opt/puppetlabs/puppet/bin/puppet module install stahnma/epel")

  # install docker
  ssh("/opt/puppetlabs/puppet/bin/puppet apply -e 'include docker'")



end

def build_image
  # Use user-supplied hostname if set
  if @hostname then
    @img_type = "private"
  else 
    @img_type = "public"
    @hostname = "pe-puppet.localdomain"
  end

  if @lowmem then
    @img_type += "_lowmem"
  end

  if @r10k_control then
    @img_type += "_r10k"
  end

  if @dockerbuild then
    @img_type += "_dockerbuild"
  end

  @basename = "pe#{@pe_version}_centos-7"
  @finalname = "#{@basename}_aio-master_#{@img_type}"
  @pe_media ="puppet-enterprise-#{@pe_version}-el-7-x86_64"
  @docker_hub_name="geoffwilliams/#{@finalname}:v#{@tag_version}"

  # create a Dockerfile from ERB template
  dockerfile_erb = File.read("Dockerfile.erb")
  dockerfile = ERB.new(dockerfile_erb, nil, '-').result(binding)


  # TODO:  Use the docker ruby API from https://github.com/swipely/docker-api
  # eg,   ::Docker::Image.build(dockerfile), { :rm => true })

  # write out fixed up dockerfile to tmpdir, run docker build and delete
  tmpdir = Dir.mktmpdir
  File.write("#{tmpdir}/Dockerfile", dockerfile)
  system(
    "cd #{tmpdir} && \
    docker build --rm -t #{@basename} . && \
    rm -rf #{tmpdir}"
  ) or abort("failed to build docker image")

  system("docker run \
    --publish-all \
    --detach=true \
    --volume /sys/fs/cgroup:/sys/fs/cgroup \
    --privileged \
    --hostname #{@hostname} \
    --env container=docker \
    --name #{@finalname} \
    #{@basename}") or abort("failed to run docker image")

  # address of the docker-machine VM (boot2docker) or just good 'ol localhost on
  # real computers
  @dm_ip=%x(docker-machine ip default 2>/dev/null|| echo localhost).strip

  # find the ssh port...
  @ssh_port=%x(docker inspect -f '{{ index .NetworkSettings.Ports "22/tcp" 0 "HostPort" }}' #{@finalname}).strip


  puts "docker-machine IP #{@dm_ip}, ssh port #{@ssh_port}"

  # wait for image to boot, then SCP the answers file
  sleep 5
  puts "uploading answers file"
  answer_file = answer_template
  scp(answer_file.path, "/root/answers.txt")
  puts "answers file uploaded"
  answer_file.unlink

  # Enable low memory (and low performance) by uploading a YAML file with some
  # puppet hiera settings 
  if @lowmem then
    hieradir = "/etc/puppetlabs/code/environments/production/hieradata"
    puts "uploading low memory hiera defaults"
    ssh("mkdir -p #{hieradir}")
    scp("./lowmem.yaml", "#{hieradir}/common.yaml")
  end


  # install puppet, then remove ssh
  ssh("
    cd /root/#{@pe_media} && \
    ./puppet-enterprise-installer -a /root/answers.txt && \
    rm /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub \
       /etc/ssh/ssh_host_dsa_key /etc/ssh/ssh_host_dsa_key.pub"
  )

  if @r10k_control then
    ssh("
      git clone #{@r10k_control_url} && \
      cd r10k-control && \
      ./bootstrap.sh
    ")
  end

  if @dockerbuild then
    setup_dockerbuild
  end

  system("docker commit #{@finalname} #{@docker_hub_name}") or abort("failed to commit docker image")
end

def main()
  parse_command_line()
  build_image()
end

main
