#!/opt/puppetlabs/puppet/bin/ruby

# Use the puppetclassify gem to add the pe_repo::platform classes to the master.
# See https://github.com/puppetlabs/puppet-classify
require 'puppetclassify'

def initialize_puppetclassify
  hostname = %x(facter fqdn).strip
  # Define the url to the classifier API
  rest_api_url = "https://#{hostname}:4433/classifier-api"

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

  # Initialize and return the puppetclassify object
  puppetclassify = PuppetClassify.new(rest_api_url, auth_info)
  puppetclassify
end

puppetclassify = initialize_puppetclassify

# Get the PE Master group from the API
#   1. Get the id of the PE Master Group
#   2. Use the id to fetch the group
pe_master_group_id = puppetclassify.groups.get_group_id('PE Master')
pe_master_group = puppetclassify.groups.get_group(pe_master_group_id)

# turn filesync off
pe_master_group["classes"]["puppet_enterprise::profile::master"]["file_sync_enabled"]=false

# code manager off
pe_master_group["classes"]["puppet_enterprise::profile::master"]["code_manager_auto_configure"]=false

# Build the hash to pass to the API
group_delta = {
  'id'      => pe_master_group_id,
  'classes' => pe_master_group["classes"]
}

# Pass the hash to the API to assign the pe_repo::platform classes
puppetclassify.groups.update_group(group_delta)

