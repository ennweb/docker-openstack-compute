#!/bin/bash

echo 'Starting compute service...'

sed -i "s/^#net.ipv4.conf.all.rp_filter.*/net.ipv4.conf.all.rp_filter=0/" /etc/sysctl.conf
sed -i "s/^#net.ipv4.conf.default.rp_filter.*/net.ipv4.conf.default.rp_filter=0/" /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

NEUTRON_CONF=/etc/neutron/neutron.conf
ML2_CONF=/etc/neutron/plugins/ml2/ml2_conf.ini
L3_AGENT=/etc/neutron/l3_agent.ini
METADATA_AGENT=/etc/neutron/metadata_agent.ini

sed -i "s/^# rpc_backend=rabbit.*/rpc_backend=rabbit/" $NEUTRON_CONF
sed -i "s/^# rabbit_host = localhost.*/rabbit_host=$CONTROLLER_HOST/" $NEUTRON_CONF
sed -i "s/^# rabbit_userid = guest.*/rabbit_userid = $RABBIT_USER/" $NEUTRON_CONF
sed -i "s/^# rabbit_password = guest.*/rabbit_password = $RABBIT_PASS/" $NEUTRON_CONF
sed -i "s/^# auth_strategy = keystone.*/auth_strategy = keystone/" $NEUTRON_CONF
sed -i "s/^auth_uri =.*/auth_uri = http:\/\/$CONTROLLER_HOST:5000/" $NEUTRON_CONF
sed -i "s/^identity_uri =.*/auth_url = http:\/\/$CONTROLLER_HOST:35357/" $NEUTRON_CONF
sed -i "s/^admin_tenant_name =.*/auth_plugin = password\nproject_domain_id = default\nuser_domain_id = default\nproject_name = service/" $NEUTRON_CONF
sed -i "s/^admin_user =.*/username = neutron/" $NEUTRON_CONF
sed -i "s/^admin_password =.*/password = $NEUTRON_PASS/" $NEUTRON_CONF
sed -i "s/^# service_plugins.*/service_plugins = router/" $NEUTRON_CONF
sed -i "s/^# allow_overlapping_ips.*/allow_overlapping_ips = True/" $NEUTRON_CONF
sed -i "s/# agent_down_time = 75.*/agent_down_time = 75/" $NEUTRON_CONF
sed -i "s/# report_interval = 30.*/report_interval = 5/" $NEUTRON_CONF

if [ "$HA_MODE" == "DVR" ]; then
    sed -i "s/^# router_distributed.*/router_distributed = True/" $NEUTRON_CONF
else
    sed -i "s/^# router_distributed.*/router_distributed = False/" $NEUTRON_CONF
fi

sed -i "s/^# type_drivers.*/type_drivers = flat,vxlan/" $ML2_CONF
sed -i "s/^# tenant_network_types.*/tenant_network_types = vxlan/" $ML2_CONF
sed -i "s/^# mechanism_drivers.*/mechanism_drivers = openvswitch,l2population/" $ML2_CONF
sed -i "s/^# vni_ranges.*/vni_ranges = 1:1000/" $ML2_CONF
sed -i "s/^# vxlan_group.*/vxlan_group = 239.1.1.1/" $ML2_CONF
sed -i "s/^# enable_security_group.*/enable_security_group = True/" $ML2_CONF
sed -i "s/^# enable_ipset.*/enable_ipset = True/" $ML2_CONF
sed -i "s/^# flat_networks.*/flat_networks = external/" $ML2_CONF
echo "firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver" >> $ML2_CONF

echo "" >> $ML2_CONF
echo "[ovs]" >> $ML2_CONF
echo "local_ip = $TUNNEL_IP" >> $ML2_CONF
echo "enable_tunneling = True" >> $ML2_CONF
echo "bridge_mappings = external:br-ex" >> $ML2_CONF

echo "" >> $ML2_CONF
echo "[agent]" >> $ML2_CONF
echo "l2population = True" >> $ML2_CONF
echo "tunnel_types = vxlan" >> $ML2_CONF

if [ "$HA_MODE" == "DVR" ]; then
    echo "enable_distributed_routing = True" >> $ML2_CONF
else
    echo "enable_distributed_routing = False" >> $ML2_CONF
fi

echo "arp_responder = True" >> $ML2_CONF

sed -i "s/^# interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver.*/interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver/" $L3_AGENT
sed -i "s/^# use_namespaces.*/use_namespaces = True/" $L3_AGENT
sed -i "s/^# router_delete_namespaces =.*/router_delete_namespaces = True/" $L3_AGENT

if [ "$HA_MODE" == "DVR" ]; then
    sed -i "s/^# agent_mode.*/agent_mode = dvr/" $L3_AGENT
else
    sed -i "s/^# agent_mode.*/agent_mode = legacy/" $L3_AGENT
fi

sed -i "s/^auth_url.*/auth_url = http:\/\/$CONTROLLER_HOST:5000\/v2.0/" $METADATA_AGENT
sed -i "s/^auth_region.*/auth_region = $REGION_NAME/" $METADATA_AGENT
sed -i "s/^admin_tenant_name.*/admin_tenant_name = service/" $METADATA_AGENT
sed -i "s/^admin_user.*/admin_user = neutron/" $METADATA_AGENT
sed -i "s/^admin_password.*/admin_password = $NEUTRON_PASS/" $METADATA_AGENT
sed -i "s/^# nova_metadata_ip.*/nova_metadata_ip = $CONTROLLER_HOST/" $METADATA_AGENT
sed -i "s/^# metadata_proxy_shared_secret.*/metadata_proxy_shared_secret = $METADATA_SECRET/" $METADATA_AGENT

service openvswitch-switch restart

ifconfig br-ex
if [ $? != 0 ]; then
    echo 'Making br-ex bridge using OVS command'
    ovs-vsctl add-br br-ex
fi

if [ "$INTERFACE_NAME" ]; then
    echo 'Add port to br-ex bridge....'
    ovs-vsctl add-port br-ex $INTERFACE_NAME
fi

service neutron-plugin-openvswitch-agent restart
service neutron-metadata-agent restart
service neutron-l3-agent restart

NOVA_CONF=/etc/nova/nova.conf
NOVA_COMPUTE=/etc/nova/nova-compute.conf

echo "my_ip = $LISTEN_IP" >> $NOVA_CONF
echo "auth_strategy = keystone" >> $NOVA_CONF
echo "network_api_class = nova.network.neutronv2.api.API" >> $NOVA_CONF
echo "security_group_api = neutron" >> $NOVA_CONF
echo "linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver" >> $NOVA_CONF
echo "firewall_driver = nova.virt.firewall.NoopFirewallDriver" >> $NOVA_CONF
echo "fixed_ip_disassociate_timeout=30" >> $NOVA_CONF
echo "enable_instance_password=False" >> $NOVA_CONF
echo "service_neutron_metadata_proxy=True" >> $NOVA_CONF
echo "neutron_metadata_proxy_shared_secret=$METADATA_SECRET" >> $NOVA_CONF
echo "rpc_backend = rabbit" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[keystone_authtoken]" >> $NOVA_CONF
echo "auth_uri = http://$CONTROLLER_HOST:5000" >> $NOVA_CONF
echo "auth_url = http://$CONTROLLER_HOST:35357" >> $NOVA_CONF
echo "auth_plugin = password" >> $NOVA_CONF
echo "project_domain_id = default" >> $NOVA_CONF
echo "user_domain_id = default" >> $NOVA_CONF
echo "project_name = service" >> $NOVA_CONF
echo "username = nova" >> $NOVA_CONF
echo "password = $NOVA_PASS" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[oslo_messaging_rabbit]" >> $NOVA_CONF
echo "rabbit_host = $CONTROLLER_HOST" >> $NOVA_CONF
echo "rabbit_userid = $RABBIT_USER" >> $NOVA_CONF
echo "rabbit_password = $RABBIT_PASS" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[vnc]" >> $NOVA_CONF
echo "enabled = True" >> $NOVA_CONF
echo "vncserver_listen = 0.0.0.0" >> $NOVA_CONF
echo "vncserver_proxyclient_address = $LISTEN_IP" >> $NOVA_CONF
echo "novncproxy_base_url = http://$CONTROLLER_HOST:6080/vnc_auto.html" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[glance]" >> $NOVA_CONF
echo "host = $CONTROLLER_HOST" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[oslo_concurrency]" >> $NOVA_CONF
echo "lock_path = /var/lib/nova/tmp" >> $NOVA_CONF

echo "" >> $NOVA_CONF
echo "[neutron]" >> $NOVA_CONF
echo "url = http://$CONTROLLER_HOST:9696" >> $NOVA_CONF
echo "auth_url = http://$CONTROLLER_HOST:35357" >> $NOVA_CONF
echo "auth_plugin = password" >> $NOVA_CONF
echo "project_domain_id = default" >> $NOVA_CONF
echo "user_domain_id = default" >> $NOVA_CONF
echo "region_name = $REGION_NAME" >> $NOVA_CONF
echo "project_name = service" >> $NOVA_CONF
echo "username = neutron" >> $NOVA_CONF
echo "password = $NEUTRON_PASS" >> $NOVA_CONF

# Select kvm/qemu
cpus=`egrep -c '(vmx|svm)' /proc/cpuinfo`
if [ $cpus -eq 0 ]; then
    sed -i "s/virt_type.*/virt_type=qemu/" $NOVA_COMPUTE
fi

service libvirt-bin restart
service nova-compute restart
