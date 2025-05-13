#!/bin/bash

set -e

# Password default untuk semua host
DEFAULT_PASSWORD="777112"

# Install Ansible dan sshpass (untuk Linux)
# Untuk koneksi ke Windows, Ansible menggunakan WinRM, tidak memerlukan sshpass
echo "Memperbarui daftar paket dan menginstal Ansible..."
apt update && apt install -y ansible sshpass -y

# Buat direktori struktur project
echo "Membuat struktur direktori proyek Ansible..."
mkdir -p ~/ansible-project/{inventory,group_vars,secrets,roles}
cd ~/ansible-project

# Buat ansible.cfg
echo "Membuat file ansible.cfg..."
cat <<EOF > ansible.cfg
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
retry_files_enabled = False
EOF

# --- Input IP Address Secara Manual ---
read -p "Masukkan IP Address untuk lin1.srv (Linux): " LINUX1_IP
read -p "Masukkan IP Address untuk lin2.srv (Linux): " LINUX2_IP
read -p "Masukkan IP Address untuk win.srv (Windows): " WINDOWS_IP
# --------------------------------------

# Buat inventory
echo "Membuat file inventory/hosts.yml..."
cat <<EOF > inventory/hosts.yml
all:
  children:
    linux_servers:
      hosts:
        lin1.srv:
          ansible_host: $LINUX1_IP
        lin2.srv:
          ansible_host: $LINUX2_IP
    windows_servers:
      hosts:
        win.srv:
          ansible_host: $WINDOWS_IP
    webservers_linux:
      hosts:
        lin1.srv:
        lin2.srv:
    webservers_windows:
      hosts:
        win.srv:
    haproxy:
      hosts:
        lin1.srv:
        lin2.srv:
    dns_linux:
      hosts:
        lin1.srv:
        lin2.srv:
    dns_windows:
      hosts:
        win.srv:

  vars:
    # Variabel default untuk semua host (bisa ditimpa di group_vars)
    ansible_user: root # Default user untuk Linux
    ansible_password: $DEFAULT_PASSWORD # Default password untuk Linux
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
EOF

# Buat variabel group
echo "Membuat file group_vars/all.yml..."
mkdir -p group_vars
cat <<EOF > group_vars/all.yml
---
# Variabel umum untuk semua host
# Ini akan ditimpa oleh variabel spesifik grup jika ada
ansible_user: root # Default user untuk Linux
ansible_password: $DEFAULT_PASSWORD # Default password untuk Linux
EOF

echo "Membuat file group_vars/windows_servers.yml..."
cat <<EOF > group_vars/windows_servers.yml
---
# Variabel khusus untuk grup windows_servers
ansible_connection: winrm
ansible_user: Administrator # Ganti dengan user Administrator Windows Anda
ansible_password: $DEFAULT_PASSWORD
ansible_winrm_transport: basic # Menggunakan Basic Auth (tidak aman untuk produksi)
ansible_winrm_server_cert_validation: ignore # Mengabaikan validasi sertifikat (tidak aman)
EOF

# Buat secrets dan enkripsi (untuk Linux become password)
echo "Menyiapkan secrets dengan Ansible Vault..."
mkdir -p secrets
echo "ansible_become_pass: $DEFAULT_PASSWORD" > secrets/vault_linux.yml
echo $DEFAULT_PASSWORD > vault_pass.txt
ansible-vault encrypt secrets/vault_linux.yml --vault-password-file=vault_pass.txt
rm vault_pass.txt

# Buat secrets dan enkripsi (untuk Windows become password, jika diperlukan)
# Windows biasanya menggunakan user Administrator, become_pass mungkin tidak perlu
# Namun, jika Anda menggunakan UAC atau user lain, ini bisa relevan
# echo "ansible_become_pass: $DEFAULT_PASSWORD" > secrets/vault_windows.yml
# ansible-vault encrypt secrets/vault_windows.yml --vault-password-file=vault_pass.txt

# ========== ROLE: Webserver Linux (Apache2) ==========
echo "Membuat role webserver Linux (Apache2)..."
mkdir -p roles/webserver_linux/{tasks,templates}
cat <<EOF > roles/webserver_linux/tasks/main.yml
---
- name: Install Apache2
  ansible.builtin.apt:
    name: apache2
    state: present
    update_cache: yes

- name: Ensure Apache2 is started and enabled
  ansible.builtin.service:
    name: apache2
    state: started
    enabled: yes

- name: Deploy custom index.html
  ansible.builtin.template:
    src: index.html.j2
    dest: /var/www/html/index.html
    mode: '0644'
EOF

cat <<EOF > roles/webserver_linux/templates/index.html.j2
<html>
  <head><title>{{ inventory_hostname }}</title></head>
  <body>
    <h1>Welcome to {{ inventory_hostname }} (Linux)</h1>
    <p>This page is served by {{ ansible_hostname }} on {{ ansible_distribution }} {{ ansible_distribution_version }}</p>
  </body>
</html>
EOF

# ========== ROLE: DNS Linux (BIND9) ==========
echo "Membuat role DNS Linux (BIND9)..."
mkdir -p roles/dns_linux/{tasks,templates}
cat <<EOF > roles/dns_linux/tasks/main.yml
---
- name: Install BIND9 DNS server
  ansible.builtin.apt:
    name: bind9
    state: present
    update_cache: yes

- name: Copy named.conf.local config
  ansible.builtin.template:
    src: named.conf.local.j2
    dest: /etc/bind/named.conf.local
    mode: '0644'

- name: Copy zone file
  ansible.builtin.template:
    src: db.srv.j2
    dest: /etc/bind/db.srv
    mode: '0644'

- name: Restart BIND9 service
  ansible.builtin.service:
    name: bind9
    state: restarted
    enabled: yes
EOF

cat <<EOF > roles/dns_linux/templates/named.conf.local.j2
zone "srv" {
    type master;
    file "/etc/bind/db.srv";
};
EOF

cat <<EOF > roles/dns_linux/templates/db.srv.j2
\$TTL    604800
@       IN      SOA     ns.srv. root.srv. (
                            2         ; Serial
                            604800    ; Refresh
                             86400    ; Retry
                           2419200    ; Expire
                            604800 )  ; Negative Cache TTL

@       IN      NS      ns.srv.
ns      IN      A       {{ hostvars['lin1.srv'].ansible_default_ipv4.address }}
lin1    IN      A       {{ hostvars['lin1.srv'].ansible_default_ipv4.address }}
lin2    IN      A       {{ hostvars['lin2.srv'].ansible_default_ipv4.address }}
win     IN      A       {{ hostvars['win.srv'].ansible_host }}
EOF

# ========== ROLE: HAProxy Linux ==========
echo "Membuat role HAProxy Linux..."
mkdir -p roles/haproxy_linux/{tasks,templates,handlers}
cat <<EOF > roles/haproxy_linux/tasks/main.yml
---
- name: Install HAProxy
  ansible.builtin.apt:
    name: haproxy
    state: present
    update_cache: yes

- name: Deploy HAProxy config
  ansible.builtin.template:
    src: haproxy.cfg.j2
    dest: /etc/haproxy/haproxy.cfg
    mode: '0644'
  notify: Restart haproxy

- name: Ensure HAProxy is started and enabled
  ansible.builtin.service:
    name: haproxy
    state: started
    enabled: yes
EOF

cat <<EOF > roles/haproxy_linux/handlers/main.yml
---
- name: Restart haproxy
  ansible.builtin.service:
    name: haproxy
    state: restarted
EOF

cat <<EOF > roles/haproxy_linux/templates/haproxy.cfg.j2
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
{% for host in groups['webservers_linux'] %}
    server {{ host }} {{ hostvars[host].ansible_default_ipv4.address }}:80 check
{% endfor %}
{% for host in groups['webservers_windows'] %}
    server {{ host }} {{ hostvars[host].ansible_host }}:80 check
{% endfor %}
EOF

# ========== ROLE: Webserver Windows (IIS) ==========
echo "Membuat role webserver Windows (IIS)..."
mkdir -p roles/webserver_windows/{tasks,templates}
cat <<EOF > roles/webserver_windows/tasks/main.yml
---
- name: Install IIS feature
  ansible.windows.win_feature:
    name: Web-Server
    state: present

- name: Ensure Default Web Site is started
  ansible.windows.win_iis_website:
    name: Default Web Site
    state: started

- name: Deploy custom index.html
  ansible.windows.win_copy:
    src: index.html
    dest: C:\inetpub\wwwroot\index.html
EOF

# Untuk Windows IIS, kita akan gunakan file statis index.html sederhana
# karena template Jinja2 dengan fakta Ansible mungkin memerlukan konfigurasi WinRM yang lebih lanjut
echo "Membuat file index.html statis untuk IIS..."
cat <<EOF > roles/webserver_windows/templates/index.html
<html>
  <head><title>Windows Webserver</title></head>
  <body>
    <h1>Welcome to Windows Webserver (IIS)</h1>
    <p>This is a simple IIS page.</p>
  </body>
</html>
EOF
# Catatan: Dalam tugas win_copy di atas, src: index.html akan mencari file di roles/webserver_windows/files/index.html
# Jadi, kita perlu memindahkan file index.html yang baru saja dibuat ke direktori 'files'
mkdir -p roles/webserver_windows/files
mv roles/webserver_windows/templates/index.html roles/webserver_windows/files/

# ========== ROLE: DNS Windows ==========
echo "Membuat role DNS Windows..."
mkdir -p roles/dns_windows/tasks
cat <<EOF > roles/dns_windows/tasks/main.yml
---
- name: Install DNS Server feature
  ansible.windows.win_feature:
    name: DNS
    state: present

- name: Create primary forward lookup zone 'srv'
  ansible.windows.win_dns_zone:
    name: srv
    type: Primary
    action: create
    replicate_to: "AllDnsServersInDomain" # Sesuaikan jika tidak dalam domain

- name: Add A record for lin1.srv
  ansible.windows.win_dns_record:
    zone: srv
    name: lin1
    type: A
    value: "{{ hostvars['lin1.srv'].ansible_host }}" # Menggunakan ansible_host dari inventory
    state: present

- name: Add A record for lin2.srv
  ansible.windows.win_dns_record:
    zone: srv
    name: lin2
    type: A
    value: "{{ hostvars['lin2.srv'].ansible_host }}"
    state: present

- name: Add A record for win.srv
  ansible.windows.win_dns_record:
    zone: srv
    name: win
    type: A
    value: "{{ hostvars['win.srv'].ansible_host }}"
    state: present

- name: Add A record for ns.srv (pointing to win.srv)
  ansible.windows.win_dns_record:
    zone: srv
    name: ns
    type: A
    value: "{{ hostvars['win.srv'].ansible_host }}" # Menggunakan win.srv sebagai NS
    state: present
EOF

# ========== PLAYBOOK UTAMA ==========
echo "Membuat file playbook utama site.yml..."
cat <<EOF > site.yml
---
- name: Setup Linux Servers
  hosts: linux_servers
  become: true
  vars_files:
    - secrets/vault_linux.yml # Menggunakan vault untuk password sudo Linux
  roles:
    - webserver_linux
    - dns_linux
    - haproxy_linux # HAProxy hanya di Linux dalam contoh ini

- name: Setup Windows Server
  hosts: windows_servers # Grup ini sekarang hanya berisi win.srv
  # become: true # Become tidak umum digunakan seperti sudo di Windows dengan WinRM Basic
  vars_files:
    # - secrets/vault_windows.yml # Gunakan jika memerlukan become_pass untuk Windows
  roles:
    - webserver_windows
    - dns_windows
    # Role haproxy_linux tidak disertakan di sini
EOF

echo "--------------------------------------------------------"
echo "Penyiapan proyek Ansible selesai!"
echo "Pastikan WinRM sudah diaktifkan di Windows Server target (win.srv)."
echo "Anda bisa menjalankan perintah berikut di PowerShell sebagai Administrator di Windows Server:"
echo "winrm quickconfig -q"
echo "winrm set winrm/config/service/auth '@{Basic=\"true\"}'"
echo "winrm set winrm/config/service '@{AllowUnencrypted=\"true\"}'"
echo "Set-NetFirewallRule -DisplayName \"Windows Remote Management (HTTP-In)\" -Enabled true"
echo ""
echo "Untuk server Linux target (lin1.srv, lin2.srv), pastikan SSH diizinkan dan login root dengan password diaktifkan (tidak disarankan untuk produksi):"
echo "sed -i 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
echo "systemctl restart sshd"
echo ""
echo "Jalankan playbook dari direktori ~/ansible-project dengan:"
echo "cd ~/ansible-project"
echo "ansible-playbook site.yml --ask-vault-pass"
echo "--------------------------------------------------------"
