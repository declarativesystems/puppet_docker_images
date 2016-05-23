#!/opt/puppetlabs/puppet/bin/ruby

# Use the puppetclassify gem to set TTLs for puppetdb to 'forever' (0s)
# to stop reports expiring.  Because the class is loaded directly in the
# classifier, we can't use hiera ADB to override the parameters so we have
# to pump values into the NC API...
# See https://github.com/puppetlabs/puppet-classify
require 'puppetclassify'

def initialize_puppetclassify
  hostname = %x(facter fqdn).strip
  port = 4433

  # Define the url to the classifier API
  rest_api_url = "https://#{hostname}:#{port}/classifier-api"

  # We need to authenticate against the REST API using a certificate
  # that is whitelisted in /etc/puppetlabs/console-services/rbac-certificate-whitelist.
  # (https://docs.puppetlabs.com/pe/latest/nc_forming_requests.html#authentication)
  #  
  # Since we're doing this on the master,
  # we can just use the internal dashboard certs for authentication
  ssl_dir     = '/etc/puppetlabs/puppet/ssl'
  ca_cert     = "#{ssl_dir}/ca/ca_crt.pem"
  cert_name   = hostname
  cert        = "#{ssl_dir}/certs/#{cert_name}.pem"
  private_key = "#{ssl_dir}/private_keys/#{cert_name}.pem"

  auth_info = {
    'ca_certificate_path' => ca_cert,
    'certificate_path'    => cert,
    'private_key_path'    => private_key,
  }

  # wait upto 5 mins for classifier to become live...
  port_open = false
  Timeout::timeout(300) do
    while not port_open
      begin
        s = TCPSocket.new(hostname, port)
        s.close
        port_open = true
        puts "Classifier signs of life detected, proceeding to classify..."
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        puts "connection refused, waiting..."
        sleep(1)
      end
    end
  end

  puppetclassify = PuppetClassify.new(rest_api_url, auth_info)

  # return
  puppetclassify
end

puppetclassify = initialize_puppetclassify

# Get the PE PuppetDB group from the API
#   1. Get the id of the PE PuppetDB
#   2. Use the id to fetch the group
pe_puppetdb_group_id = puppetclassify.groups.get_group_id('PE PuppetDB')
pe_puppetdb_group = puppetclassify.groups.get_group(pe_puppetdb_group_id)

# set TTLs to forever
pe_puppetdb_group["classes"]["puppet_enterprise::profile::puppetdb"]["node_purge_ttl"]="0s"
pe_puppetdb_group["classes"]["puppet_enterprise::profile::puppetdb"]["node_ttl"]="0s"
pe_puppetdb_group["classes"]["puppet_enterprise::profile::puppetdb"]["report_ttl"]="0s"

# Build the hash to pass to the API
group_delta = {
  'id'      => pe_puppetdb_group_id,
  'classes' => pe_puppetdb_group["classes"]
}

# Pass the hash to the API to assign the pe_repo::platform classes
puppetclassify.groups.update_group(group_delta)
puts "Normal exit"
