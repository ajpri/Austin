#!/bin/bash

# Installing Docker
sudo dnf install dnf-plugins-core -y
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo -y
sudo dnf install docker-ce docker-ce-cli containerd.io -y
sudo systemctl start docker
sudo systemctl enable docker

#Spinning Up Portainer and Watchtower
sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
sudo docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower

#Installing XCP-ng Guest Utilities
sudo yum install xe-guest-utilities-latest -y
sudo systemctl enable xe-linux-distribution
sudo systemctl start xe-linux-distribution

#Install additional software
sudo dnf install neofetch -y
sudo dnf install nano -y

# Setup Mail to point to server
sudo dnf install -y ssmtp
sudo cp /etc/ssmtp/ssmtp.conf /etc/ssmtp/ssmtp.conf.orig
sudo bash -c 'cat > /etc/ssmtp/ssmtp.conf' << EOF
mailhub=10.102.0.111:2525
UseTLS=NO
UseSTARTTLS=NO
hostname=localhost
EOF

# Test the configuration by sending a test email
echo "$HOSTNAME is configured" | mail -s "Test Email" ultralife@pritchett.info

echo "Done."
