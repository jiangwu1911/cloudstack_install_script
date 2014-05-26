#!/bin/sh

DB_USER="root"
DB_PASSWORD="password"
vm_name=$1

if [ -z $vm_name ]; then
    echo -e "\nUsage: $0 <vm_name>\n"
    exit 1
fi

# Get the VNC port
port=$(ps -ef | grep qemu | grep $vm_name | sed -e 's/.*-vnc//' | sed -e 's/,.*//')
if [ -z $port ]; then
    echo -e "\nVirtual machine '$vm_name' does not exist.\n"
    exit 2
fi

# Get the encrypted password from Database
enc_password=$(echo "SELECT vnc_password FROM cloud.vm_instance WHERE instance_name = '$vm_name'" \
                | mysql -u $DB_USER -p$DB_PASSWORD \
                | tail -1)
if [ -z $enc_password ]; then
    echo -e "\nCannot find virtual machine '$vm_name' in database.\n"
    exit 3
fi

# Decrypt password
password=$(java -cp /usr/share/cloudstack-common/lib/jasypt-1.9.0.jar \
                org.jasypt.intf.cli.JasyptPBEStringDecryptionCLI \
                input="$enc_password" \
                password="$DB_PASSWORD" \
                | grep -v "^$" \
                | tail -1)
echo -e "\nVNC port:    $port"
echo -e   "VNC password: $password"
echo
