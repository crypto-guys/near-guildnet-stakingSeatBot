#!/bin/bash
# SCRIPT CONFIG
# This script was created by # Rickrods @ crypto-solutions.net for the NEAR Guildnet Network
# 

set -eu

# Get Ubuntu Version so we build the right one
RELEASE=$(lsb_release -c -s)
# Change this to compile a different Version
NEAR_VERSION="1.16.2"
# Change this to use a different repo
NEAR_REPO="https://github.com/solutions-crypto/nearcore.git"
vm_name="compiler"

##############
# User Section
# NOTE: You are not required to run the compile process it is options.
# but the file /tmp/near/nearcore.tar is required for the install portion of the script
# The tar file contains 1 folder named binaries with all binaries inside of it
#######################################################################################################

# Ensure the user has root privilages to execute the script
if [ "$USER" != "root" ]
then
echo " You must run this script with sudo privilage hint: "sudo ./install.sh" -->>EXITING>>>!!!"
exit
fi

echo "***  Do you want to compile the nearcore binaries?  y/n?  ***"
read -r NEAR_COMPILE

echo "***  Do you want to install the NEARD guildnet Service? This is dependent upon the file generated by the compile step above  y/n?  ***"
read -r NEARD_INSTALL

echo "***  Please enter the nearcore version to compile... example - 1.17.0-rc.2 ***"
read -r NEAR_VERSION

if [ "$NEARD_INSTALL" == y ]
then
echo "***  Please input your validator-id  ***"
read -r VALIDATOR_ID
fi

#######################################################################################################
# This section has all funcitons the script will use they are ignored unless called upon
#######################################################################################################

# Update and install required packages
function update_via_apt
{
    echo "* Updating via APT and installing required packages"
    apt-get -qq update && apt-get -qq upgrade
    apt-get -qq install snapd squashfs-tools git curl python3
    sleep 5
    echo '* Install lxd using snap'
    snap install lxd

}

# Initializes the container software with preseed information.
# NOTE: advanced init configs using "cloud-init" require cloud-tools and it is highly sugggested to use a cloud image
function init_lxd
{
echo "* Initializing LXD"
    cat <<EOF | lxd init --preseed
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: auto
  description: ""
  name: lxdbr1
  type: ""
  project: default
storage_pools:
- config: {}
  description: ""
  name: compiler-storage
  driver: dir
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: lxdbr1
      type: nic
    root:
      path: /
      pool: guildnet
      type: disk
  name: default
cluster: null
EOF

systemctl restart snapd
sleep 15
}

function launch_container
{
    echo "* Detected Ubuntu $RELEASE"
    echo "* Launching Ubuntu $RELEASE LXC container to build in"

    if [ "$RELEASE" == "focal" ]
    then
    lxc launch images:ubuntu/focal/cloud/amd64 ${vm_name}
    fi
    if [ "$RELEASE" == "bionic" ]
    then
    lxc launch images:ubuntu/18.04/cloud/amd64 ${vm_name}
    fi

    echo "* Pausing for 15 seconds while the container initializes"
    sleep 15
    echo "* Install Required Packages to the container via APT"
    sudo lxc exec ${vm_name} -- sh -c "apt-get -q -y autoremove && apt-get -q -y autoclean && apt-get -q -y update && apt-get -q -y upgrade"
    sudo lxc exec ${vm_name} -- sh -c "apt-get -y install git curl snapd squashfs-tools libclang-dev build-essential g++ make cmake clang libssl-dev"
    sudo lxc exec ${vm_name} -- sh -c "snap install rustup --classic && rustup default nightly"
}

function compile_source
{
    echo "* Cloning the github source"
    sudo lxc exec ${vm_name} -- sh -c "rm -rf /tmp/src && mkdir -p /tmp/src/ && git clone ${NEAR_REPO} /tmp/src/nearcore"
    echo "* Switching Version"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore && git checkout $NEAR_VERSION"
    echo "* Attempting to compile"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore && cargo build -p neard --release"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore && cargo build -p keypair-generator --release"
    sudo lxc exec ${vm_name} -- sh -c "mkdir ~/binaries"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore/target/release/ && mv near nearcore"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore/target/release/ && cp /tmp/src/nearcore/target/release/neard ~/binaries/"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp/src/nearcore/target/release/ && cp /tmp/src/nearcore/target/release/keypair-generator ~/binaries/"
    sudo lxc exec ${vm_name} -- sh -c "cd /tmp && tar -cf nearcore.tar -C ~/ binaries/"
}

# Create a tar file of the binaries and puts them in /tmp/near/nearcore.tar
function get_tarball
{
    echo "* Retriving the tarball and storing in /tmp/near/nearcore.tar"
    mkdir -p /usr/lib/near/guildnet
    mkdir -p /tmp/near
    lxc file pull ${vm_name}/tmp/nearcore.tar /tmp/near/nearcore.tar
}


# This function is the main function that installes the components required for compiling the source
# It also compiles the code and exports the results in a tar file
function compile_nearcore
{
    update_via_apt
    init_lxd
    launch_container
    compile_source
    get_tarball
    echo "***  The compile process has completed the binaries were stored in /tmp/near/nearcore.tar"
}

function create_user_and_group
{
    echo '* Guildnet Install Script Starting'
    echo '* Setting up required accounts, groups, and privilages'
    # Adding group NEAR for any NEAR Services such as Near Exporter
    near_group=$( cat /etc/group | grep near )
    if [ -z "$near_group" ]
    then
        groupadd near
    fi
    # Adding an unprivileged user for the neard service
    neard_user=$( cat /etc/passwd | grep neard )
    if [ -z "$neard_user" ]
    then
        adduser --system --home /home/neard --disabled-login --ingroup near neard || true
    fi
}

# Creating a system service that will run with the non privilaged service account neard-guildnet
function create_neard_service
{
    # Copy Guildnet Files to a suitable location
    mkdir -p /home/neard/service
    wget https://raw.githubusercontent.com/crypto-guys/near-guildnet/main/nearcore/install/neard.service --output-file /home/neard/service/neard.service
    sudo rm -rf /etc/systemd/system/neard.service && sudo ln -s /home/neard/service/neard.service /etc/systemd/system/neard.service
    cd /tmp/near
    tar -xf nearcore.tar
    sudo cp -p /tmp/near/binaries/* /usr/local/

    echo '* Getting the correct files and fixing permissions'
    sudo mkdir -p /home/neard/.near/guildnet
    sudo neard --home /home/neard/.near/guildnet init --download-genesis --chain-id guildnet --account-id "$VALIDATOR_ID"
    sudo chown -R neard-guildnet:near -R /home/neard/.near

    echo '* Adding logfile conf for neard'
    sudo mkdir -p /usr/lib/systemd/journald.conf.d
    sudo wget https://raw.githubusercontent.com/crypto-guys/near-guildnet/main/nearcore/install/near.conf --output-file /usr/lib/systemd/journald.conf.d/neard.conf
    echo '* Deleting temp files'
    rm -rf /tmp/near/binaries/
    echo '* The NEARD service is installed and ready to be enabled and started'
    echo '* Use "sudo systemctl enable neard.service" to enable the service to run on boot'
    echo '* Use "sudo systemctl start neard" to start the service'
    echo '* Once enabled and workng the service will start upon every system boot'
    echo '* The data files for the neard service are located here -->  /home/neard/.near/guildnet '
    verify_install
}

function verify_install 
{
    echo '* Starting verification of the neard system service installation'
    installed_version=$(neard --version)
    echo '* Verify ---  Was the neard binary file installed correctly?'
    neard_user_check=$(grep neard < /etc/passwd)
    if [ -z "$installed_version" ]
    then
    echo '* The neard binary file is not active please check /usr/local/bin/ and look for errors above'
    return 1
    fi
    echo '* Verify --- Does the installed neard version match the intended version?'
    if [ "$installed_version" != "$NEAR_VERSION" ]
    then
    echo '* The installed neard binary version is not what we intended to build. Please check for any errors above'
    return 1
    fi
    echo '* Verify --- Does the neard user exist on the system?'
    if [ -z "$neard_user_check" ]
    then
    echo '* The neard user account (neard) has not been created something failed with the install script'
    return 1
    fi

    echo '* Verification of the installation is complete. success!!!'
}    
#######################################################################################################


#######################################################################################################
# Use user supplied input to determine which parts of the script to run

# Compile
if [ "$NEAR_COMPILE" == "y" ]
then
compile_nearcore
echo '* The compiled files are located in /tmp/near/nearcore.tar'
fi

# Install
if [ "$NEARD_INSTALL" == "y" ]
then
create_user_and_group
create_neard_service
fi
