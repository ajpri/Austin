#! /bin/bash
echo "Requesting Superuser Permission"
sudo ls > /dev/null

echo "Installing Git"
sudo apt install git -y
git clone https://github.com/FOGProject/fogproject.git
sudo ./fogproject/bin/installfog.sh
