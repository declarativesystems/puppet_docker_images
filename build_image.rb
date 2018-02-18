#!/usr/bin/env ruby

require 'logger'
require 'getoptlong'
require 'tmpdir'
require 'tempfile'
require 'erb'
require 'docker'
require 'pe_info/tarball'
require 'pe_info/system'

STDOUT.sync = true
@logger = Logger.new(STDOUT)

@default_hostname = "pe-puppet.localdomain"

def show_usage()
  puts <<-EOF
build_image --pe-version VERSION \
            --tag-version VERSION \
            [--hostname puppet.megacorp.com] \
            [--no-regular] \
            [--r10k-control GIT_URL] \
            [--no-dockerbuild] \
            [--no-cleanup] \
            [--old-installer]
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
  Version of Puppet Enterprise you are installing, eg '2015.2.1'
  Does not download the image, you must have the downloaded 
  tarball present in the directory your running this script from

--tag-version VERSION
  Numeric version number to tag the release with, eg 0

--base-tag-version VERSION
  Numveric version number to *base* the lowmem image on (eg if
  you want to build 2016.1.2-3 lowmem on top of 2016.1.2-2 master)

--hostname
  Hostname to install Puppet Enterprise for

--no-regular
  Do not create a docker image for a regualr Puppet Enterprise server

--no-r10k
  Do not bootstrap R10K from https://github.com/GeoffWilliams/r10k-control

--r10k-control GIT_URL
  Supply an alternate GIT_URL to bootstrap r10k from.  Defautls to 
  https://github.com/GeoffWilliams/r10k-control.  Only supports R10K
  control repositories forked from the above URL and implementing a 
  bootstrap.sh install script

--no-cleanup
  Do not remove the Docker container after build

--old-installer
  Use the old PE installer (answers file) instead of the 'new' meep one

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
    [ '--hostname',         GetoptLong::REQUIRED_ARGUMENT ],
    [ '--root-passwd',      GetoptLong::REQUIRED_ARGUMENT ],
    [ '--pe-version',       GetoptLong::REQUIRED_ARGUMENT ],
    [ '--tag-version',      GetoptLong::REQUIRED_ARGUMENT ],
    [ '--base-tag-version', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--no-r10k',          GetoptLong::NO_ARGUMENT ],
    [ '--r10k-control',     GetoptLong::REQUIRED_ARGUMENT ],
    [ '--no-regular',       GetoptLong::NO_ARGUMENT ],
    [ '--no-cleanup',       GetoptLong::NO_ARGUMENT ],
    [ '--old-installer',    GetoptLong::NO_ARGUMENT ],
    [ '--help',             GetoptLong::NO_ARGUMENT ],
    [ '--debug',            GetoptLong::NO_ARGUMENT ],
  )
  @cleanup          = true
  @lowmem           = true
  @regular          = true
  @code_dir         = "/etc/puppetlabs/code"
  @global_mod_dir   = "#{@code_dir}/modules"
  @prod_hiera_dir   = "#{@code_dir}/environments/production/hieradata"
  @r10k_control     = true
  @r10k_control_url = "https://github.com/GeoffWilliams/r10k-control"
  @old_installer    = false

  opts.each do |opt,arg|
    case opt
    when '--help'
      show_usage()
    when '--hostname'
      @hostname = arg
    when '--root-passwd'
      @root_passwd = arg
    when '--pe-version'
      @pe_version = arg
    when '--tag-version'
      @tag_version = arg
    when '--base-tag-version'
      @base_tag_version = arg
    when '--no-r10k'
      @r10k_control = false
    when '--r10k-control'
      @r10k_control_url = arg
    when '--no-cleanup'
      @cleanup = false
    when '--no-regular'
      @regular = false
    when '--old-installer'
      @old_installer = true
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

def puppet_agent_t 
  return "while [ -f /opt/puppetlabs/puppet/cache/state/agent_catalog_run.lock ]; do  sleep 1; echo .; done ; puppet agent -t"
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
    if command =~ /puppet agent/ and out[2] == 2
      @logger.info("Exit status 2 (changes) from puppet agent is OK - proceeding")
      ignore_error = true
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

def image_name(lowmem)
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
  temp_dockerfile = "Dockerfile.out"

  dockerfile_erb = File.read("Dockerfile.erb")
  dockerfile = ERB.new(dockerfile_erb, nil, '-').result(binding)

  # must write out the dockerfile to a tempfile to obtain build context
  # then we need to manually clean up
  File.write(temp_dockerfile, dockerfile)

  @logger.debug("building image from dockerfile...")
  base_image = Docker::Image.build_from_dir(".", { 
    'dockerfile' => temp_dockerfile,
    :rm => true 
  }) { |chunk|
    @logger.debug(chunk)
  }
  @logger.debug("...done!")
  File.delete(temp_dockerfile)

  # return
  base_image  
end

def docker_hub_name(finalname, tag_version=@tag_version)
  "geoffwilliams/#{finalname}:#{@pe_version}-#{tag_version}"
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
  finalname = image_name(false)
  pe_media ="puppet-enterprise-#{@pe_version}-el-7-x86_64"
  docker_hub=docker_hub_name(finalname)

  begin
    base_image = image_from_dockerfile()
    container = make_container(base_image, finalname)
  rescue Docker::Error::UnexpectedResponseError => e
    puts("Did you copy the PE master installation tarball for RHEL7 to the current directory before running this script?")
    raise
  rescue => e
    puts("Error preparing image from Dockerfile, see next error")
    raise
  end

  # wait for image to boot, then copy the answers file
  sleep 5
  if @old_installer
    @logger.debug("uploading answers file")
    answer_file = answer_template
    scp(container, answer_file.path, "/root/answers.txt")
    puts "answers file uploaded"
    answer_file.unlink
    pe_install_cmd = "./puppet-enterprise-installer -a /root/answers.txt"
  else
    @logger.debug("uploading meep config file")
    scp(container, "answers/pe.conf", "/root/pe.conf")
    puts "meep config file uploaded"
    pe_install_cmd = "./puppet-enterprise-installer -c /root/pe.conf"
  end

  # upload agent installers if available
  agent_version = PeInfo::Tarball::agent_version(pe_media + '.tar.gz')
  Dir.chdir("#{Dir.home}/agent_installers/#{@pe_version}") {
    Dir.foreach(".") { |f|
      if f =~ /puppet-agent/
        @logger.debug("uploading agent installer #{f}")
        upload_dir = PeInfo::System::agent_installer_upload_path(@pe_version, agent_version, f)
        # upload to container, ruby API doesn't seem to have native support
        ssh(container, "mkdir -p #{upload_dir}")
        scp(container, f, upload_dir)
      end
    }
  }

  # install puppet, deactivate filesync via NC API (its the only way)
  # and then run puppet
  @logger.debug("installing puppet...")
  ssh(
    container,
    "cd /root/#{pe_media} && \
    #{pe_install_cmd} && \
    mkdir -p #{@global_mod_dir} && \
    /opt/puppetlabs/puppet/bin/gem install puppetclassify && \
    /opt/puppetlabs/puppet/bin/gem install pe_rbac && \
    /opt/puppetlabs/puppet/bin/gem install ncio && \
    /opt/puppetlabs/puppet/bin/gem install ncedit && \

    /opt/puppetlabs/server/bin/puppetserver gem install puppetclassify && \
    systemctl restart pe-puppetserver && \
    #{puppet_agent_t}
  ")

  if @r10k_control then

    @logger.debug("installing r10k...")
      ssh(
        container,
	"/opt/puppetlabs/puppet/bin/ncedit classes --group-name 'PE Master' --class-name puppet_enterprise::profile::master --param-name r10k_remote --param-value #{@r10k_control_url} && #{puppet_agent_t} ; /opt/puppetlabs/puppet/bin/r10k deploy environment -pv ; systemctl restart pe-puppetserver && sleep 120 && ncedit classes --group-name 'Site Puppet Masters' --class-name r_role::puppet::master --rule '[\"and\", [\"=\",[\"fact\",\"fqdn\"],\"'$(facter fqdn)'\"]]' --rule-mode replace"
      )


      @logger.debug("running puppet...")
      ssh(container, puppet_agent_t)
  end

  # run puppet - to generate a node in the console/prove it still works after
  # the installation
  @logger.debug("running puppet...")
  ssh(container, puppet_agent_t)

    
  @logger.info("DONE! committing container...")
  system("docker commit #{finalname} #{docker_hub}") or abort("failed to commit docker image")

  cleanup(finalname)
end

# lowmem + dockerbuild is done with an existing image to 
def lowmem()
  finalname = image_name(true)
  docker_hub=docker_hub_name(finalname)

  # get the name of the 'normal' puppet image, allowing base_tag_version to
  # override tag version (for disjoint releases between master and 
  # dockerbuild+lowmem images
  base_image = ::Docker::Image.get(
    docker_hub_name(
      image_name(false), 
      @base_tag_version||@tag_version
    )
  )

  container = make_container(base_image, finalname)

  # Enable low memory (and low performance) by uploading a YAML file with some
  # puppet hiera settings.  We do this AFTER we have installed puppet into a 
  # container so that we don't have to rebuild it
  if @r10k_control then
    @logger.debug("Copying extra YAML for r10K environments")
    dest_file = "#{@code_dir}/system.yaml"
  else
    # without R10K, just copy to the default location
    @logger.debug("Copying extra YAML for vanila environments")
    dest_file = "#{@prod_hiera_dir}/common.yaml"
  end
  @logger.debug("uploading low memory hiera defaults to #{dest_file}")
  ssh(container, "mkdir -p #{File.dirname(dest_file)}")
  scp(container, "./lowmem.yaml", dest_file)


  # copy NC API script to turn off node/report TTLs and run it
  scp(container, "classify_ttl_forever.rb", "/usr/local/classify_ttl_forever.rb")
  ssh(container, "chmod +x /usr/local/classify_ttl_forever.rb && /usr/local/classify_ttl_forever.rb")

  # make the yaml/hiera settings take effect
  @logger.debug("running puppet...")
  ssh(container, puppet_agent_t)

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
  @logger.info("*** BUILDING LOWMEM IMAGE***")
  lowmem()
  @logger.info("*** DONE BUILDING LOWMEM IMAGE***")
end

main
