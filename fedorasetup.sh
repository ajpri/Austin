#!/bin/bash

# Installing Docker
sudo dnf install dnf-plugins-core -y
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo -y
sudo dnf install docker-ce docker-ce-cli containerd.io -y
sudo systemctl start docker
sudo systemctl enable docker

#Spinning Up Portainer and Watchtower
sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
sudo docker run -d --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower

#Installing XCP-ng Guest Utilities
sudo yum install xe-guest-utilities-latest -y
sudo systemctl enable xe-linux-distribution
sudo systemctl start xe-linux-distribution

#Install additional software
sudo dnf install neofetch -y
sudo dnf install nano -y
