#!/bin/bash

# Installing Docker
sudo dnf install dnf-plugins-core -y
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo -y
sudo dnf install docker-ce docker-ce-cli containerd.io -y
sudo systemctl start docker
sudo systemctl enable docker

#Run Docker Prune Sunday at 1am
echo "0 1 * * 0 root docker image prune -f" | sudo tee -a /etc/crontab

#Installing XCP-ng Guest Utilities
sudo yum install xe-guest-utilities-latest -y
sudo systemctl enable xe-linux-distribution
sudo systemctl start xe-linux-distribution

#Install additional software
sudo dnf install neofetch -y
sudo dnf install nano -y
sudo dnf install mailx -y

# Setup Mail to point to server
sudo dnf install -y ssmtp
sudo cp /etc/ssmtp/ssmtp.conf /etc/ssmtp/ssmtp.conf.orig
sudo bash -c 'cat > /etc/ssmtp/ssmtp.conf' << EOF
mailhub=notify.pritchett.info:2525
UseTLS=NO
UseSTARTTLS=NO
hostname=$(hostname)
EOF

# Test the configuration by sending a test email
echo "$HOSTNAME is configured" | mail -s "Test Email" ultralife@pritchett.info

#Spinning Up Portainer and Watchtower
sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
sudo docker run -d \
  --name watchtower \
  --restart=always \
  -e WATCHTOWER_NOTIFICATIONS=email \
  -e WATCHTOWER_NOTIFICATION_EMAIL_FROM=$(hostname)@pritchett.info \
  -e WATCHTOWER_NOTIFICATION_EMAIL_TO=notify@pritchett.info \
  -e WATCHTOWER_NOTIFICATION_EMAIL_SERVER=notify.pritchett.info \
  -e WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=2525 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower

echo "Done."
