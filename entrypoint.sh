#!/bin/bash

echo 'Starting compute service...'

sed -i "\
  s/^# rpc_backend=rabbit.*/rpc_backend=rabbit/; \
  s/^# rabbit_host = localhost.*/rabbit_host=$CONTROLLER_HOST/; \
  s/^# rabbit_userid = guest.*/rabbit_userid = $RABBIT_USER/; \
  s/^# rabbit_password = guest.*/rabbit_password = $RABBIT_PASS/; \
  s/^# auth_strategy = keystone.*/auth_strategy = keystone/; \
  s/^auth_uri =.*/auth_uri = http:\/\/$CONTROLLER_HOST:5000/; \
  s/^identity_uri =.*/auth_url = http:\/\/$CONTROLLER_HOST:35357/; \
  s/^admin_tenant_name =.*/auth_plugin = password\nproject_domain_id = default\nuser_domain_id = default\nproject_name = service/; \
  s/^admin_user =.*/username = neutron/; \
  s/^admin_password =.*/password = $NEUTRON_PASS/; \
" /etc/neutron/neutron.conf

sed -i "\
  s/# physical_interface_mappings.*/physical_interface_mappings = public:$INTERFACE_NAME/; \
  s/# enable_vxlan.*/enable_vxlan = True/; \
  s/# local_ip.*/local_ip = $LOCAL_IP/; \
  s/# l2_population.*/l2_population = True/; \
  s/^\[agent\]/[agent]\n\nprevent_arp_spoofing = True/; \
  s/# enable_security_group.*/enable_security_group = True/; \
  s/# firewall_driver.*/firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver/; \
" /etc/neutron/plugins/ml2/linuxbridge_agent.ini

NOVA_CONF=/etc/nova/nova.conf
NOVA_COMPUTE=/etc/nova/nova-compute.conf

echo "my_ip = $LISTEN_IP" >> $NOVA_CONF
echo "auth_strategy = keystone" >> $NOVA_CONF
echo "network_api_class = nova.network.neutronv2.api.API" >> $NOVA_CONF
echo "security_group_api = neutron" >> $NOVA_CONF
echo "linuxnet_interface_driver = nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver" >> $NOVA_CONF
echo "firewall_driver = nova.virt.firewall.NoopFirewallDriver" >> $NOVA_CONF
echo "fixed_ip_disassociate_timeout=30" >> $NOVA_CONF
echo "enable_instance_password=False" >> $NOVA_CONF
echo "service_neutron_metadata_proxy=True" >> $NOVA_CONF
echo "neutron_metadata_proxy_shared_secret=$METADATA_SECRET" >> $NOVA_CONF
echo "rpc_backend = rabbit" >> $NOVA_CONF
echo "live_migration_flag = VIR_MIGRATE_UNDEFINE_SOURCE,VIR_MIGRATE_PEER2PEER,VIR_MIGRATE_LIVE,VIR_MIGRATE_PERSIST_DEST,VIR_MIGRATE_TUNNELLED" >> $NOVA_CONF

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
echo "vncserver_listen = $LISTEN_IP" >> $NOVA_CONF
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

if [ "$STORE_BACKEND" == "ceph" ]; then
  echo "" >> $NOVA_CONF
  echo "[libvirt]" >> $NOVA_CONF
  echo "images_type = rbd" >> $NOVA_CONF
  echo "images_rbd_pool = vms" >> $NOVA_CONF
  echo "images_rbd_ceph_conf = /etc/ceph/ceph.conf" >> $NOVA_CONF
  echo "rbd_user = cinder" >> $NOVA_CONF
  echo "rbd_secret_uuid = $UUID" >> $NOVA_CONF
  echo "inject_password = false" >> $NOVA_CONF
  echo "inject_key = false" >> $NOVA_CONF
  echo "inject_partition = -2" >> $NOVA_CONF
  echo "hw_disk_discard = unmap" >> $NOVA_CONF
fi

# Select kvm/qemu
cpus=`egrep -c '(vmx|svm)' /proc/cpuinfo`
if [ $cpus -eq 0 ]; then
    sed -i "s/virt_type.*/virt_type=qemu/" $NOVA_COMPUTE
fi

service libvirt-bin restart
service nova-compute restart
service neutron-plugin-linuxbridge-agent restart

if [ "$STORE_BACKEND" == "ceph" ]; then
  cat > secret.xml <<EOF
  <secret ephemeral='no' private='no'>
  <uuid>$UUID</uuid>
  <usage type='ceph'>
  <name>client.cinder secret</name>
  </usage>
  </secret>
EOF
  virsh secret-define --file secret.xml
  virsh secret-set-value --secret $UUID --base64 $(grep key /etc/ceph/ceph.client.cinder.keyring | awk '{printf "%s", $NF}') && rm secret.xml
fi

# Disable libvirt network
virsh net-destroy default

## Setup complete
echo 'Setup complete!...'

while true
  do sleep 1
done
