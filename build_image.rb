#!/usr/bin/env ruby

require 'logger'
require 'getoptlong'
require 'tmpdir'
require 'tempfile'
require 'erb'
require 'docker'

STDOUT.sync = true
@logger = Logger.new(STDOUT)

@default_hostname = "pe-puppet.localdomain"

def show_usage()
  puts <<-EOF
build_image --pe-version VERSION \
            --tag-version VERSION \
            [--hostname puppet.megacorp.com] \
            [--no-regular] \
            [--no-lowmem] \
            [--r10k-control GIT_URL] \
            [--no-dockerbuild] \
            [--no-cleanup]
Build a suit of docker images with Puppet Enterprise installed
and optionally configure a specific hostname.

By default, the following builds are created:
* Regular PE monolithic master
* Low Memory PE monolithic master
* Dockerbuild (Docker-in-Docker) low memory puppet master for 
  creating Docker images

Options
-------
--pe-version VERSION
  Version of Puppet Enterprise to download and install, eg '2015.2.1'

--tag-version VERSION
  Numeric version number to tag the release with, eg 0

--hostname
  Hostname to install Puppet Enterprise for

--no-regular
  Do not create a docker image for a regualr Puppet Enterprise server

--no-lowmem
  Do not create a Docker image for Puppet Enterprise in a low-memory 
  environment

--no-r10k
  Do not bootstrap R10K from https://github.com/GeoffWilliams/r10k-control

--r10k-control GIT_URL
  Supply an alternate GIT_URL to bootstrap r10k from.  Defautls to 
  https://github.com/GeoffWilliams/r10k-control.  Only supports R10K
  control repositories forked from the above URL and implementing a 
  bootstrap.sh install script

--no-dockerbuild
  Do not produce a dockerbuild image.

--no-cleanup
  Do not remove the Docker container after build

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
    [ '--no-r10k',        GetoptLong::NO_ARGUMENT ],
    [ '--r10k-control',   GetoptLong::REQUIRED_ARGUMENT ],
    [ '--no-regular',     GetoptLong::NO_ARGUMENT ],
    [ '--no-lowmem',      GetoptLong::NO_ARGUMENT ],
    [ '--no-dockerbuild', GetoptLong::NO_ARGUMENT ],
    [ '--no-cleanup',     GetoptLong::NO_ARGUMENT ],
    [ '--help',           GetoptLong::NO_ARGUMENT ],
    [ '--debug',          GetoptLong::NO_ARGUMENT ],
  )
  @cleanup        = true
  @lowmem         = true
  @dockerbuild    = true
  @regular        = true
  @global_mod_dir = "/etc/puppetlabs/code/modules"
  @r10k_control   = true
  @r10k_control_url = "https://github.com/GeoffWilliams/r10k-control"

  opts.each do |opt,arg|
    case opt
    when '--help'
      show_usage()
    when '--hostname'
      @hostname = arg
    when '--no-lowmem'
      @lowmem = false
    when '--root-passwd'
      @root_passwd = arg
    when '--pe-version'
      @pe_version = arg
    when '--tag-version'
      @tag_version = arg
    when '--no-dockerbuild'
      @dockerbuild = false
    when '--no-r10k'
      @r10k_control = false
    when '--r10k-control'
      @r10k_control_url = arg
    when '--no-cleanup'
      @cleanup = false
    when '--no-regular'
      @regular = false
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

  if @tag_version.nil? or ! (@tag_version =~ /\d+/) then
    puts "You must specify a numeric tag for the image"
    show_usage()
  end

  if @hostname.nil?
    @hostname = @default_hostname
  end
end

def scp(container, local_file, remote_file)
  # doesn't seem to be an API call for this, copy() looks to do an upload...
  cmd = "docker cp #{local_file} #{container.id}:/#{remote_file}"
  @logger.info(cmd)
  system(cmd)
end

def ssh(container, command)
  command_real = "export PATH=/opt/puppetlabs/puppet/bin/:${PATH}; #{command}"
  @logger.info("running bash -c + ---> #{command_real}...")
  # container exec MUST be passed an array...
  out = container.exec(["bash", "-c", command_real]) { |stream, chunk| 
    @logger.debug(chunk)
  }
  if out[2] != 0
    ignore_error = false
    for line in out[1]
      if line =~ /integer expression expected/
        @logger.info("Please ignore the integer expression expected error (known issue)")
        ignore_error = true
      end
    end
    if not ignore_error
      @logger.error("intercepted error running command, killing build")
      abort("ERROR running command, aborting build: " + out[1].to_s)
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

def setup_dockerbuild(container)
  # download script and module to './build' directory, then SCP to host
  # if not already there.  If files already exist, they are used directly.
  # This is to allow in-place testing of local files
  build_dir = "./build"
  docker_mod = "garethr-docker"
  dockerbuild = "puppet-dockerbuild"
  docker_mod_dir = "#{build_dir}/#{docker_mod}"
  dockerbuild_dir = "#{build_dir}/#{dockerbuild}"
  docker_mod_gh = "https://github.com/garethr/#{docker_mod}"
  dockerbuild_gh = "https://github.com/GeoffWilliams/#{dockerbuild}"
  git_clone = "git clone"
  FileUtils.mkdir_p(build_dir)
  if ! Dir.exists?(docker_mod_dir) then
    system("#{git_clone} #{docker_mod_gh} #{docker_mod_dir}")
  end
  if ! Dir.exists?(dockerbuild_dir) then
    system("#{git_clone} #{dockerbuild_gh} #{dockerbuild_dir}")
  end
  Dir.chdir(build_dir)
    
  @logger.debug("uploading dockerbuild files...")
  scp(container, "./#{docker_mod}", "#{@global_mod_dir}/docker")
  scp(container, "./#{dockerbuild}", "/opt")
  
  # install gems and modules needed for script
    @logger.debug("installing dockerbuild requirements...")  
  ssh(container, "yum install -y ruby-devel e2fsprogs xfsprogs" )
  ssh(container, "gem install excon docker-api sinatra ansi-to-html")
  ssh(container, "/opt/puppetlabs/puppet/bin/puppet module install puppetlabs/stdlib")
  ssh(container, "/opt/puppetlabs/puppet/bin/puppet module install puppetlabs/apt")
  ssh(container, "/opt/puppetlabs/puppet/bin/puppet module install stahnma/epel")

  # install docker
  @logger.debug("uploading docker...")
  ssh(container, "/opt/puppetlabs/puppet/bin/puppet apply -e 'include docker'")

  # dockerbuild systemd unit
  @logger.debug("setting up systemd for docker...")
  ssh(container, "cp /opt/puppet-dockerbuild/dockerbuild.service /etc/systemd/system && systemctl enable /etc/systemd/system/dockerbuild.service")

  @logger.info("..DONE! setup of dockerbuild is complete")
end


def image_name(lowmem, dockerbuild)
  if @hostname == @default_hostname then
    img_type = "public"
  else
    img_type = "private"
  end

  if lowmem then
    img_type += "_lowmem"
  end

  if @r10k_control then
    img_type += "_r10k"
  end

  if dockerbuild then
    img_type += "_dockerbuild"
  end

  @basename = "pe_master"
  @finalname = "#{@basename}_#{img_type}"
  return @finalname
end

def make_container(base_image, finalname)
  @logger.info("creating container...")

  container_opts = {
    "name"      => finalname,
    "Image"     => base_image.id,
    "Hostname"  => @hostname,
    "Volumes"   => {
      "/sys/fs/cgroup" => {}
    }
  }

  start_opts = {
    "PublishAllPorts" => true,
    "Privileged"      => true,
  }

  # kill any existing container
  begin
    existing_container = ::Docker::Container.get(finalname)
    if existing_container
      @logger.info("killing existing container #{finalname}")
      existing_container.delete(:force => true)
    end
  rescue Docker::Error::NotFoundError
    @logger.debug("container doesn't exist yet - good")
  end
  container = Docker::Container.create(container_opts)
  @logger.info("container created, starting...")
  container.start!(start_opts)
  @logger.info("...done!")

  # return
  container
end

# make an image from a dockerfile template and return it
def image_from_dockerfile()
  @logger.debug("creating dockerfile from template...")
  dockerfile_erb = File.read("Dockerfile.erb")
  dockerfile = ERB.new(dockerfile_erb, nil, '-').result(binding)

  @logger.debug("building image from dockerfile...")
  base_image = Docker::Image.build(dockerfile, { :rm => true }) { |chunk|
    @logger.debug(chunk)
  }
  @logger.debug("...done!")

  # return
  base_image  
end

def docker_hub_name(finalname)
  "geoffwilliams/#{finalname}:#{@pe_version}-#{@tag_version}"
end

def cleanup(finalname)
  # kill running container
  if @cleanup
    @logger.info("deleting #{finalname}")
    system("docker rm -f #{finalname}") or
      abort("failed to kill running docker containerker image")
  end
end


def build_main_image()
  # Use user-supplied hostname if set
  finalname = image_name(false, false)
  pe_media ="puppet-enterprise-#{@pe_version}-el-7-x86_64"
  docker_hub=docker_hub_name(finalname)

  base_image = image_from_dockerfile()
  container = make_container(base_image, finalname)

  # wait for image to boot, then SCP the answers file
  sleep 5
  @logger.debug("uploading answers file and scripts")
  answer_file = answer_template
  scp(container, answer_file.path, "/root/answers.txt")
  scp(container, "classify_filesync_off.rb", "/usr/local/bin/")
  puts "answers file uploaded"
  answer_file.unlink

  # install puppet, deactivate filesync via NC API (its the only way)
  # and then run puppet
  @logger.debug("installing puppet...")
  ssh(
    container,
    "cd /root/#{pe_media} && \
    ./puppet-enterprise-installer -a /root/answers.txt && \
    mkdir -p #{@global_mod_dir} && \
    gem install puppetclassify && \
    chmod +x /usr/local/bin/classify_filesync_off.rb && \
    /usr/local/bin/classify_filesync_off.rb && \
    puppet agent -t
  ")

  if @r10k_control then
   @logger.debug("installing r10k...")
    # install a custom fact to setup this machine as a master, then bootstrap r10k
    ssh(
      container,
      "mkdir -p /etc/puppetlabs/facter/facts.d/
      echo 'role=role::puppet::master' > /etc/puppetlabs/facter/facts.d/role.txt
      git clone #{@r10k_control_url} && \
      cd r10k-control && \
      ./bootstrap.sh
    ")

    # after our initial puppet run, we can put run r10k to deploy again to get
    # rid of our files dropped by the nasty hack above :(
    @logger.debug("running puppet and deploying r10k...")
    ssh(container, "puppet agent -t && r10k deploy environment -pv")
  end

  # run puppet - to generate a node in the console/prove it still works after
  # the installation
  @logger.debug("running puppet...")
  ssh(container, "puppet agent -t")

    
  @logger.info("DONE! committing container...")
  system("docker commit #{finalname} #{docker_hub}") or abort("failed to commit docker image")

  cleanup(finalname)
end

# lowmem + dockerbuild is done with an existing image to 
def lowmem_dockerbuild()
  finalname = image_name(true, true)
  docker_hub=docker_hub_name(finalname)

  # get the name of the 'normal' puppet image
  base_image = ::Docker::Container.get(::Docker::Container.get(false, false))

  container = make_container(base_image, finalname)

  # Enable low memory (and low performance) by uploading a YAML file with some
  # puppet hiera settings.  We do this AFTER we have installed puppet into a 
  # container so that we don't have to rebuild it
  dest_files = ["/etc/puppetlabs/code/environments/production/hieradata/common.yaml"]
  if @r10k_control then
    @logger.debug("yaml adjustment...")
    # copy an extra version of the file as our initial one will be clobbered
    # by r10k if its in use
    dest_files.push("/etc/puppetlabs/code/system.yaml")
  end

  for dest_file in dest_files
    @logger.debug("uploading low memory hiera defaults to #{dest_file}")
    ssh(container, "mkdir -p #{File.dirname(dest_file)}")
    scp(container, "./lowmem.yaml", dest_file)
  end

  if @r10k_control
    @logger.debug("setup defaults in common.yaml")
    # Nasty hack - once we classify with the master with role::puppet::master
    # and run the puppet agent, we will be running puppet before we have
    # recreated the hierarchy so we need to ensure our dockerbuild settings
    # are in place AND the r10k_control defaults!  Append them to common.yaml
    # temporarily.  Once the hierarchy is configured, the system will read
    # system.yaml by default.  We have to use tail instead of cat because if
    # we dont, we get the yaml file separator and everything breaks
    ssh(container, "tail -n+2 /etc/puppetlabs/code/system.yaml >> \
          /etc/puppetlabs/code/environments/production/hieradata/common.yaml")
  end
  

  setup_dockerbuild(container)

  @logger.info("DONE! committing container...")
  system("docker commit #{finalname} #{docker_hub}") or abort("failed to commit docker image")

  cleanup(finalname)
end

def main()
  parse_command_line()

  # docker library setup
  ::Docker.options = { :write_timeout => 900, :read_timeout => 900 }.merge(::Docker.options || {})

  # normal image
  if @regular then
    @logger.info("*** BUILDING MAIN IMAGE***")
    build_main_image()
    @logger.info("*** DONE BUILDING MAIN IMAGE***")
  end

  # lowmem + dockerbuild
  if @dockerbuild then
    @logger.info("*** BUILDING LOWMEM IMAGE***")
    lowmem_dockerbuild()
    @logger.info("*** BUILDING LOWMEM IMAGE***")
  end
end

main
