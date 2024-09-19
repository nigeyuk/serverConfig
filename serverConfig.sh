#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'  # Magenta color for category headings
NC='\033[0m' # No Color

# Create a log directory and define log file with timestamp
LOG_DIR="./log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(basename "$0")_$(date +'%Y%m%d_%H%M%S').log"

pause() {
    echo -e "${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s
}

# Function to log messages
log_message() {
    echo -e "${YELLOW}$(date +'%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
    log_message "${RED}ERROR: $1${NC}"
    exit 1
}

# Functions for menu options
update_system() {
    log_message "${GREEN}Updating the system...${NC}"
    sudo apt-get update && sudo apt-get upgrade -y
    if [ $? -eq 0 ]; then
        log_message "${GREEN}System updated successfully.${NC}"
	pause
    else
        error_exit "Failed to update the system."
	pause
    fi
}

change_hostname() {
    echo -e "${BLUE}Enter new hostname:${NC}"
    read new_hostname
    sudo hostnamectl set-hostname "$new_hostname" && log_message "${GREEN}Hostname changed to $new_hostname${NC}" || error_exit "Failed to change hostname."
	pause # Pause and wait for user input before returning to the main menu
}

add_user() {
    echo -e "${BLUE}Enter username to add:${NC}"
    read username

    # Add the new user
    sudo adduser --disabled-password --gecos "" $username || error_exit "Failed to add user $username."
    log_message "${GREEN}User added: $username${NC}"

    # Create the .ssh directory for the user and set permissions
    sudo mkdir -p /home/$username/.ssh || error_exit "Failed to create .ssh directory for $username."
    sudo chmod 700 /home/$username/.ssh || error_exit "Failed to set permissions on .ssh directory."

    # Generate SSH key pair for the user
    sudo ssh-keygen -t rsa -b 4096 -f /home/$username/.ssh/id_rsa -N "" -C "$username@$(hostname)" || error_exit "Failed to generate SSH keys for $username."
    log_message "${GREEN}SSH key pair generated for $username.${NC}"

    # Set the appropriate ownership and permissions
    sudo chown -R $username:$username /home/$username/.ssh || error_exit "Failed to set ownership of .ssh directory for $username."
    sudo chmod 600 /home/$username/.ssh/id_rsa || error_exit "Failed to set permissions on private key."
    sudo chmod 644 /home/$username/.ssh/id_rsa.pub || error_exit "Failed to set permissions on public key."

    # Add the public key to authorized_keys
    sudo cp /home/$username/.ssh/id_rsa.pub /home/$username/.ssh/authorized_keys || error_exit "Failed to copy public key to authorized_keys."
    sudo chmod 600 /home/$username/.ssh/authorized_keys || error_exit "Failed to set permissions on authorized_keys."
    sudo chown $username:$username /home/$username/.ssh/authorized_keys || error_exit "Failed to set owner on authorized_keys."
    log_message "${GREEN}SSH public key added to authorized_keys for $username.${NC}"

    # Display the public key for the admin to distribute
    echo -e "${YELLOW}Public key for user $username:${NC}"
    sudo cat /home/$username/.ssh/id_rsa.pub

    pause  # Pause before returning to the main menu
}

setup_firewall() {
    log_message "${GREEN}Setting up the firewall...${NC}"
    sudo ufw enable || error_exit "Failed to enable firewall."
    sudo ufw allow 80/tcp || error_exit "Failed to allow HTTP."
    sudo ufw allow 443/tcp || error_exit "Failed to allow HTTPS."
    ssh_port=$(sudo grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    ssh_port=${ssh_port:-22}
    sudo ufw allow $ssh_port/tcp || error_exit "Failed to allow SSH port $ssh_port."
    log_message "${GREEN}Firewall setup with HTTP, HTTPS, and SSH (Port $ssh_port).${NC}"
	pause # Pause and wait for user input before returning to the main menu
}

setup_swap() {
    log_message "${GREEN}Setting up swap space...${NC}"
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    log_message "${GREEN}Swap setup complete.${NC}"
	pause # Pause and wait for user input before returning to the main menu
	
}

setup_ssh() {
    log_message "${GREEN}Setting up SSH...${NC}"
    sudo apt-get install openssh-server -y || error_exit "Failed to install SSH server."
    log_message "${GREEN}SSH setup complete.${NC}"
	pause # Pause and wait for user input before returning to the main menu
}

change_ssh_port() {
    echo -e "${MAGENTA}Enter new SSH port number:${NC}"
    read ssh_port

    # Backup the current sshd_config file
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup || error_exit "Failed to backup sshd_config."

    # Get the current SSH port and handle cases where Port might be commented out
    current_ssh_port=$(grep -E "^#?Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$current_ssh_port" ]; then
        current_ssh_port=22  # Default SSH port if not explicitly set
    fi

    # Change the SSH port in the configuration file, removing any leading comment if necessary
    sudo sed -i "s/^#\?Port .*/Port $ssh_port/" /etc/ssh/sshd_config || error_exit "Failed to change SSH port in sshd_config."

    # Restart the SSH service to apply the new port
    sudo systemctl restart ssh || error_exit "Failed to restart SSH service."

    # Update the firewall to allow the new SSH port and remove the old port rule if necessary
    sudo ufw allow $ssh_port/tcp || error_exit "Failed to allow SSH port $ssh_port."
    if [ "$ssh_port" != "$current_ssh_port" ]; then
        sudo ufw delete allow $current_ssh_port/tcp || error_exit "Failed to remove old SSH port $current_ssh_port from firewall."
    fi

    log_message "${GREEN}SSH port changed to $ssh_port and firewall updated.${NC}"
	pause # Pause and wait for user input before returning to the main menu
}


install_packages() {
    log_message "${YELLOW}Reading package list from server_packages...${NC}"
    # Extract categories from the file
    categories=$(awk '/^# Category:/{gsub(/^# Category: /, ""); print}' server_packages)
    echo -e "${MAGENTA}Available categories:${NC}"
    
    # Read categories into an array
    declare -a category_array
    while IFS= read -r line; do
        category_array+=("$line")
    done <<< "$categories"

    for i in "${!category_array[@]}"; do
        echo -e "${MAGENTA}$((i+1)). ${category_array[i]}${NC}"
    done

    # User selects a category by number
    echo -e "${YELLOW}Enter the number of the category you wish to install packages from:${NC}"
    read category_num
    selected_category="${category_array[$((category_num-1))]}"

    if [ -z "$selected_category" ]; then
        log_message "${RED}Invalid category selection.${NC}"
        return
    fi

    log_message "${GREEN}Selected Category: $selected_category${NC}"
    # Filter packages by selected category, capturing lines until the next category header or end of file
    packages=$(awk -v cat="Category: $selected_category" '/^# Category:/ {flag=0} $0 ~ cat {flag=1; next} flag && NF' server_packages)
    
    echo -e "${BLUE}Packages to install from '$selected_category':${NC}"
    echo -e "${GREEN}$packages${NC}"
    echo -e "${YELLOW}Proceed with installation? (yes/no)${NC}"
    read confirm
    if [[ "$confirm" == "yes" ]]; then
        echo "$packages" | xargs sudo apt-get install -y
        if [ $? -eq 0 ]; then
            log_message "${GREEN}Packages installed successfully.${NC}"
			pause # Pause and wait for user input before returning to the main menu
        else
            error_exit "Failed to install packages."
			pause # Pause and wait for user input before returning to the main menu
        fi
    else
        log_message "${GREEN}Package installation canceled.${NC}"
    fi
}

# Main menu loop
while true; do
    clear
    echo -e "${BLUE}System Administration Menu${NC}"
    echo -e "${GREEN}1. Update System${NC}"
    echo -e "${GREEN}2. Change Hostname${NC}"
    echo -e "${GREEN}3. Add User${NC}"
    echo -e "${GREEN}4. Setup Firewall${NC}"
    echo -e "${GREEN}5. Setup Swap${NC}"
    echo -e "${GREEN}6. Setup SSH${NC}"
    echo -e "${GREEN}7. Change SSH Port${NC}"
    echo -e "${GREEN}8. Install Packages${NC}"
    echo -e "${GREEN}9. Exit${NC}"
    echo -e "${YELLOW}Enter your choice:${NC} "
    read choice

    case "$choice" in
        1) update_system;;
        2) change_hostname;;
        3) add_user;;
        4) setup_firewall;;
        5) setup_swap;;
        6) setup_ssh;;
        7) change_ssh_port;;
        8) install_packages;;
        9) log_message "${GREEN}Exiting system administration script.${NC}"; break;;
        *) echo -e "${RED}Invalid option.${NC}" && sleep 2;;
    esac
done

