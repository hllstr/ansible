#!/bin/bash

set -e

# Install Ansible dan sshpass
apt update && apt install -y ansible sshpass

# Buat direktori struktur project
mkdir -p ~/ansible-project/{inventory,group_vars,secrets,roles}
cd ~/ansible-project

# Buat ansible.cfg
cat <<EOF > ansible.cfg
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
retry_files_enabled = False
EOF

# Buat inventory
cat <<EOF > inventory/hosts.yml
all:
  children:
    webservers:
      hosts:
        lin1.srv:
          192.168.18.134
        lin2.srv:
          192.168.18.136
    haproxy:
      hosts:
        lin1.srv:
        lin2.srv:
    dns:
      hosts:
        lin1.srv:
        lin2.srv:
  vars:
    ansible_user: root
    ansible_password: 777112
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
EOF

# Buat variabel group
mkdir -p group_vars
cat <<EOF > group_vars/all.yml
---
ansible_user: root
ansible_password: 777112
EOF

# Buat secrets dan enkripsi
mkdir -p secrets
echo 'ansible_become_pass: 777112' > secrets/vault.yml
echo 777112 > vault_pass.txt
ansible-vault encrypt secrets/vault.yml --vault-password-file=vault_pass.txt

# ========== ROLE: Webserver ==========
mkdir -p roles/webserver/{tasks,templates}
cat <<EOF > roles/webserver/tasks/main.yml
---
- name: Install Apache2
  apt:
    name: apache2
    state: present
    update_cache: yes

- name: Ensure Apache2 is started and enabled
  service:
    name: apache2
    state: started
    enabled: yes

- name: Deploy custom index.html
  template:
    src: index.html.j2
    dest: /var/www/html/index.html
    mode: '0644'
EOF

cat <<EOF > roles/webserver/templates/index.html.j2
<html>
  <head><title>{{ inventory_hostname }}</title></head>
  <body>
    <h1>Welcome to {{ inventory_hostname }}</h1>
    <p>This page is served by {{ ansible_hostname }} on {{ ansible_distribution }} {{ ansible_distribution_version }}</p>
  </body>
</html>
EOF

# ========== ROLE: DNS ==========
mkdir -p roles/dns/{tasks,templates}
cat <<EOF > roles/dns/tasks/main.yml
---
- name: Install BIND9 DNS server
  apt:
    name: bind9
    state: present
    update_cache: yes

- name: Copy named.conf.local config
  template:
    src: named.conf.local.j2
    dest: /etc/bind/named.conf.local
    mode: '0644'

- name: Copy zone file
  template:
    src: db.srv.j2
    dest: /etc/bind/db.srv
    mode: '0644'

- name: Restart BIND9 service
  service:
    name: bind9
    state: restarted
    enabled: yes
EOF

cat <<EOF > roles/dns/templates/named.conf.local.j2
zone "srv" {
    type master;
    file "/etc/bind/db.srv";
};
EOF

cat <<EOF > roles/dns/templates/db.srv.j2
\$TTL    604800
@       IN      SOA     ns.srv. root.srv. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

@       IN      NS      ns.srv.
ns      IN      A       {{ hostvars['lin1.srv'].ansible_default_ipv4.address }}
lin1    IN      A       {{ hostvars['lin1.srv'].ansible_default_ipv4.address }}
lin2    IN      A       {{ hostvars['lin2.srv'].ansible_default_ipv4.address }}
EOF

# ========== ROLE: HAProxy ==========
mkdir -p roles/haproxy/{tasks,templates,handlers}
cat <<EOF > roles/haproxy/tasks/main.yml
---
- name: Install HAProxy
  apt:
    name: haproxy
    state: present
    update_cache: yes

- name: Deploy HAProxy config
  template:
    src: haproxy.cfg.j2
    dest: /etc/haproxy/haproxy.cfg
    mode: '0644'
  notify: Restart haproxy

- name: Ensure HAProxy is started and enabled
  service:
    name: haproxy
    state: started
    enabled: yes
EOF

cat <<EOF > roles/haproxy/handlers/main.yml
---
- name: Restart haproxy
  service:
    name: haproxy
    state: restarted
EOF

cat <<EOF > roles/haproxy/templates/haproxy.cfg.j2
global
    log /dev/log    local0
    maxconn 2048
    daemon

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend http_front
    bind *:8080
    default_backend http_back

backend http_back
    balance roundrobin
{% for host in groups['webservers'] %}
    server {{ host }} {{ hostvars[host].ansible_default_ipv4.address }}:80 check
{% endfor %}
EOF

# ========== PLAYBOOK UTAMA ==========
cat <<EOF > site.yml
---
- name: Setup Webserver
  hosts: webservers
  become: true
  vars_files:
    - secrets/vault.yml
  roles:
    - webserver

- name: Setup DNS Server
  hosts: dns
  become: true
  vars_files:
    - secrets/vault.yml
  roles:
    - dns

- name: Setup HAProxy
  hosts: haproxy
  become: true
  vars_files:
    - secrets/vault.yml
  roles:
    - haproxy
EOF

echo "Setup selesai! Jalankan playbook dengan:"
echo "cd ~/ansible-project"
echo "ansible-playbook site.yml --ask-vault-pass"