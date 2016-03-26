# Copyright 2014 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

include ::tripleo::packages

create_resources(sysctl::value, hiera('sysctl_settings'), {})

if count(hiera('ntp::servers')) > 0 {
  include ::ntp
}

file { ['/etc/libvirt/qemu/networks/autostart/default.xml',
        '/etc/libvirt/qemu/networks/default.xml']:
  ensure => absent,
  before => Service['libvirt'],
}
# in case libvirt has been already running before the Puppet run, make
# sure the default network is destroyed
exec { 'libvirt-default-net-destroy':
  command => '/usr/bin/virsh net-destroy default',
  onlyif  => '/usr/bin/virsh net-info default | /bin/grep -i "^active:\s*yes"',
  before  => Service['libvirt'],
}

include ::nova
include ::nova::config
include ::nova::compute

nova_config {
  'DEFAULT/my_ip':                     value => $ipaddress;
  'DEFAULT/linuxnet_interface_driver': value => 'nova.network.linux_net.LinuxOVSInterfaceDriver';
}

$rbd_ephemeral_storage = hiera('nova::compute::rbd::ephemeral_storage', false)
$rbd_persistent_storage = hiera('rbd_persistent_storage', false)
if $rbd_ephemeral_storage or $rbd_persistent_storage {
  include ::ceph::profile::client

  $client_keys = hiera('ceph::profile::params::client_keys')
  $client_user = join(['client.', hiera('ceph_client_user_name')])
  class { '::nova::compute::rbd':
    libvirt_rbd_secret_key => $client_keys[$client_user]['secret'],
  }
}

if hiera('cinder_enable_nfs_backend', false) {
  if str2bool($::selinux) {
    selboolean { 'virt_use_nfs':
      value      => on,
      persistent => true,
    } -> Package['nfs-utils']
  }

  package {'nfs-utils': } -> Service['nova-compute']
}

include ::nova::compute::libvirt
include ::nova::network::neutron
include ::neutron

class { '::neutron::plugins::ml2':
  flat_networks        => split(hiera('neutron_flat_networks'), ','),
  tenant_network_types => [hiera('neutron_tenant_network_type')],
}

if 'opendaylight' in hiera('neutron_mechanism_drivers') {

  if str2bool(hiera('opendaylight_install', 'false')) {
    $controller_ips = split(hiera('controller_node_ips'), ',')
    if hiera('opendaylight_enable_ha', false) {
      $odl_ovsdb_iface = "tcp:${controller_ips[0]}:6640 tcp:${controller_ips[1]}:6640 tcp:${controller_ips[2]}:6640"
      # Workaround to work with current puppet-neutron
      # This isn't the best solution, since the odl check URL ends up being only the first node in HA case
      $opendaylight_controller_ip = $controller_ips[0]
      # Bug where netvirt:1 doesn't come up right with HA
      # Check ovsdb:1 instead
      $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/ovsdb:1'
    } else {
      $opendaylight_controller_ip = $controller_ips[0]
      $odl_ovsdb_iface = "tcp:${opendaylight_controller_ip}:6640"
      $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/netvirt:1'
    }
  } else {
    $opendaylight_controller_ip = hiera('opendaylight_controller_ip')
    $odl_ovsdb_iface = "tcp:${opendaylight_controller_ip}:6640"
    $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/netvirt:1'
  }

  # co-existence hacks for SFC
  if hiera('opendaylight_features', 'odl-ovsdb-openstack') =~ /odl-ovsdb-sfc-rest/ {
    $opendaylight_port = hiera('opendaylight_port')
    $odl_username = hiera('opendaylight_username')
    $odl_password = hiera('opendaylight_password')
    $sfc_coexist_url = "http://${opendaylight_controller_ip}:${opendaylight_port}/restconf/config/sfc-of-renderer:sfc-of-renderer-config"
    # Coexist for SFC
    exec { 'Check SFC table offset has been set':
      command   => "curl --fail --silent -u ${odl_username}:${odl_password} ${sfc_coexist_url} | grep :11 > /dev/null",
      tries     => 15,
      try_sleep => 60,
      path      => '/usr/sbin:/usr/bin:/sbin:/bin',
      before    => Class['neutron::plugins::ovs::opendaylight'],
    }
  }

  class { 'neutron::plugins::ovs::opendaylight':
      odl_controller_ip => $opendaylight_controller_ip,
      tunnel_ip         => hiera('neutron::agents::ml2::ovs::local_ip'),
      odl_port          => hiera('opendaylight_port'),
      odl_username      => hiera('opendaylight_username'),
      odl_password      => hiera('opendaylight_password'),
  }

} elsif 'onos_ml2' in hiera('neutron_mechanism_drivers') {
  $controller_ips = split(hiera('controller_node_ips'), ',')
  class {'onos::ovs_computer':
    manager_ip => $controller_ips[0]
  }

} else {
  class { 'neutron::agents::ml2::ovs':
    bridge_mappings => split(hiera('neutron_bridge_mappings'), ','),
    tunnel_types    => split(hiera('neutron_tunnel_types'), ','),
  }
}

if 'cisco_n1kv' in hiera('neutron_mechanism_drivers') {
  class { '::neutron::agents::n1kv_vem':
    n1kv_source  => hiera('n1kv_vem_source', undef),
    n1kv_version => hiera('n1kv_vem_version', undef),
  }
}


include ::ceilometer
include ::ceilometer::config
include ::ceilometer::agent::compute
include ::ceilometer::agent::auth

$snmpd_user = hiera('snmpd_readonly_user_name')
snmp::snmpv3_user { $snmpd_user:
  authtype => 'MD5',
  authpass => hiera('snmpd_readonly_user_password'),
}
class { '::snmp':
  agentaddress => ['udp:161','udp6:[::1]:161'],
  snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
}

hiera_include('compute_classes')
package_manifest{'/var/lib/tripleo/installed-packages/overcloud_compute': ensure => present}
