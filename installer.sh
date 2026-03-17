#!/bin/bash

# Minecraft Bedrock Server Auto Installer v5.0 - Enterprise Edition
# Dengan SFTP Jail + Uninstaller

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Konfigurasi global
SCRIPT_VERSION="5.0"
MIN_DISK_SPACE=1024  # MB
MIN_RAM_PER_SERVER=512  # MB
SSH_PORT=22
SFTP_JAIL_PATH="/home/sftp-jail"

# Fungsi untuk menampilkan banner
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Minecraft Bedrock Server Auto Installer v$SCRIPT_VERSION        ║"
    echo "║         (Enterprise Edition - SFTP Jail)                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Fungsi untuk logging
log() {
    local message=$1
    local color=${2:-$GREEN}
    local timestamp=$(date '+%H:%M:%S')
    echo -e "${color}[$timestamp] $message${NC}"
}

# Fungsi untuk error handling
error_exit() {
    log "❌ $1" "$RED"
    exit 1
}

# Fungsi untuk generate random password
generate_password() {
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9!@#$%^&*' | fold -w 16 | head -n 1
}

# Fungsi untuk setup SFTP jail
setup_sftp_jail() {
    log "Setting up SFTP jail environment..." "$YELLOW"
    
    # Install OpenSSH jika belum ada
    if ! command -v sshd &> /dev/null; then
        log "Installing OpenSSH server..." "$YELLOW"
        apt install -y openssh-server
    fi
    
    # Buat jail directory
    mkdir -p "$SFTP_JAIL_PATH"
    chmod 755 "$SFTP_JAIL_PATH"
    
    # Configure SSH for SFTP jail
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d)"
    
    # Backup original config
    cp "$sshd_config" "$backup_file"
    log "✓ SSH config backed up to $backup_file" "$GREEN"
    
    # Add SFTP jail configuration if not exists
    if ! grep -q "Match Group sftp-users" "$sshd_config"; then
        cat >> "$sshd_config" << EOF

# SFTP Jail Configuration
Match Group sftp-users
    ChrootDirectory $SFTP_JAIL_PATH/%u
    ForceCommand internal-sftp
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF
        log "✓ SFTP jail configuration added" "$GREEN"
    else
        log "ℹ SFTP jail already configured" "$YELLOW"
    fi
    
    # Create sftp-users group if not exists
    if ! getent group sftp-users >/dev/null; then
        groupadd sftp-users
        log "✓ Group sftp-users created" "$GREEN"
    fi
    
    # Restart SSH
    systemctl restart sshd
    log "✓ SSH service restarted" "$GREEN"
}

# Fungsi untuk setup user dengan SFTP jail
setup_sftp_user() {
    local username=$1
    local server_folder=$2
    local password=$3
    
    log "Setting up SFTP user: $username" "$YELLOW"
    
    # Create user if not exists
    if ! id "$username" &>/dev/null; then
        # Buat user dengan home directory di jail
        useradd -m -d "/home/$username" -s /usr/sbin/nologin -G sftp-users "$username"
        
        # Set password
        echo "$username:$password" | chpasswd
        log "✓ User $username created with password: $password" "$GREEN"
        
        # Force password change on first login (optional)
        # chage -d 0 "$username"
    else
        log "⚠ User $username already exists" "$YELLOW"
        # Add to sftp-users group if not already
        usermod -a -G sftp-users "$username"
    fi
    
    # Setup jail structure
    local user_jail="$SFTP_JAIL_PATH/$username"
    mkdir -p "$user_jail"
    chown root:root "$user_jail"
    chmod 755 "$user_jail"
    
    # Create server folder link
    mkdir -p "$user_jail/home"
    
    # Bind mount server folder to jail
    if [ ! -L "$user_jail/home/$username" ] && [ ! -d "$user_jail/home/$username" ]; then
        # Create mount point
        mkdir -p "$user_jail/home/$username"
        
        # Bind mount (persistent)
        if ! grep -q "$user_jail/home/$username" /etc/fstab; then
            echo "/home/minecraft/$server_folder $user_jail/home/$username none bind 0 0" >> /etc/fstab
        fi
        
        # Mount now
        mount --bind "/home/minecraft/$server_folder" "$user_jail/home/$username"
        log "✓ Server folder mounted to jail" "$GREEN"
    fi
    
    # Set permissions
    chown "$username:sftp-users" "/home/minecraft/$server_folder"
    chmod 755 "/home/minecraft/$server_folder"
    
    # Create .ssh directory for key-based auth (optional)
    mkdir -p "/home/$username/.ssh"
    chown "$username:$username" "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    
    log "✓ SFTP jail setup complete for $username" "$GREEN"
    log "  SFTP Access: sftp://$username@$(hostname -I | awk '{print $1}'):$SSH_PORT" "$CYAN"
    log "  Jail root: $user_jail" "$CYAN"
}

# Fungsi untuk setup user Minecraft (non-jail, untuk run server)
setup_minecraft_user() {
    local username=$1
    
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash -d "/home/$username" "$username"
        log "✓ Minecraft user $username created" "$GREEN"
    fi
}

# Fungsi untuk setup user dengan pilihan password
setup_user_with_password() {
    local server_index=$1
    local default_username="mcserver$server_index"
    local server_folder=$2
    
    echo -e "\n${PURPLE}━━━━━━ User Configuration for Server #$server_index ━━━━━━${NC}"
    
    # Username
    log "Username untuk SFTP access (default: $default_username):" "$BLUE"
    read -r sftp_username
    [ -z "$sftp_username" ] && sftp_username="$default_username"
    
    # Password
    log "Pilih metode password:" "$BLUE"
    echo "  1) Generate random password (recommended)"
    echo "  2) Masukkan password manual"
    log "Pilihan (default: 1):" "$BLUE"
    read -r password_choice
    
    local sftp_password
    case $password_choice in
        2)
            while true; do
                log "Masukkan password (min 8 karakter):" "$BLUE"
                read -s sftp_password
                echo
                log "Konfirmasi password:" "$BLUE"
                read -s sftp_password_confirm
                echo
                
                if [ "$sftp_password" != "$sftp_password_confirm" ]; then
                    log "❌ Password tidak cocok!" "$RED"
                elif [ ${#sftp_password} -lt 8 ]; then
                    log "❌ Password minimal 8 karakter!" "$RED"
                else
                    break
                fi
            done
            ;;
        *)
            sftp_password=$(generate_password)
            log "✓ Random password generated" "$GREEN"
            ;;
    esac
    
    # Save user info
    sftp_users+=("$sftp_username|$sftp_password|$server_folder")
    
    # Create Minecraft user (for running server)
    setup_minecraft_user "$default_username"
    
    # Setup SFTP user
    setup_sftp_user "$sftp_username" "$server_folder" "$sftp_password"
}

# Fungsi untuk uninstall server
uninstall_server() {
    echo -e "\n${RED}══════════════════════════════════════════════════════════${NC}"
    log "UNINSTALL SERVER - DESTRUCTIVE ACTION" "$RED"
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    
    # List available servers
    log "Available servers:" "$CYAN"
    local servers=()
    local i=1
    
    for dir in /home/minecraft/*; do
        if [ -d "$dir" ] && [ -f "$dir/bedrock_server" ]; then
            server_name=$(basename "$dir")
            servers+=("$server_name")
            
            # Get service status
            if systemctl is-active --quiet "$server_name.service" 2>/dev/null; then
                status="${GREEN}RUNNING${NC}"
            else
                status="${RED}STOPPED${NC}"
            fi
            
            # Get users
            users=$(find /home -maxdepth 1 -type d -name "mcserver*" -exec basename {} \; 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
            
            echo -e "  $i) $server_name - $status"
            echo -e "     Users: $users"
            ((i++))
        fi
    done
    
    if [ ${#servers[@]} -eq 0 ]; then
        log "❌ No Minecraft servers found" "$RED"
        return 1
    fi
    
    # Select server to uninstall
    echo
    log "Pilih server yang akan di-uninstall (nomor):" "$BLUE"
    read -r server_choice
    
    if ! [[ "$server_choice" =~ ^[0-9]+$ ]] || [ "$server_choice" -lt 1 ] || [ "$server_choice" -gt ${#servers[@]} ]; then
        log "❌ Pilihan tidak valid" "$RED"
        return 1
    fi
    
    local selected_server="${servers[$((server_choice-1))]}"
    
    # Double confirmation
    echo
    log "⚠⚠⚠ PERINGATAN! ⚠⚠⚠" "$RED"
    log "Anda akan menghapus server: $selected_server" "$RED"
    log "Termasuk semua data, user, service, dan konfigurasi!" "$RED"
    log "Ketik 'DELETE $selected_server' untuk konfirmasi:" "$BLUE"
    read -r confirmation
    
    if [ "$confirmation" != "DELETE $selected_server" ]; then
        log "❌ Uninstall dibatalkan" "$YELLOW"
        return 1
    fi
    
    log "Memulai uninstall server $selected_server..." "$YELLOW"
    
    # 1. Stop and disable service
    log "Stopping service..." "$YELLOW"
    systemctl stop "$selected_server.service" 2>/dev/null
    systemctl disable "$selected_server.service" 2>/dev/null
    
    # 2. Remove systemd service file
    log "Removing systemd service..." "$YELLOW"
    rm -f "/etc/systemd/system/$selected_server.service"
    systemctl daemon-reload
    
    # 3. Remove from fstab mounts
    log "Removing bind mounts..." "$YELLOW"
    sed -i "\|/home/minecraft/$selected_server|d" /etc/fstab
    
    # 4. Find and remove SFTP users associated with this server
    log "Removing SFTP users..." "$YELLOW"
    for user_file in /home/*; do
        username=$(basename "$user_file")
        if [ -d "$user_file" ]; then
            # Check if this user has bind mount to this server
            if grep -q "/home/minecraft/$selected_server" /etc/fstab 2>/dev/null; then
                # Remove from sftp-users group
                gpasswd -d "$username" sftp-users 2>/dev/null
                
                # Remove jail directory
                rm -rf "$SFTP_JAIL_PATH/$username"
                
                # Remove user (optional - comment if you want to keep user)
                log "Remove user $username? [y/N]" "$BLUE"
                read -r remove_user
                if [[ "$remove_user" =~ ^[Yy]$ ]]; then
                    userdel -r "$username" 2>/dev/null
                    log "✓ User $username removed" "$GREEN"
                fi
            fi
        fi
    done
    
    # 5. Remove Minecraft server user (mcserverX)
    log "Removing Minecraft users..." "$YELLOW"
    for mcuser in /home/mcserver*; do
        if [ -d "$mcuser" ]; then
            username=$(basename "$mcuser")
            # Check if this user owns the server folder
            if [ "$(stat -c '%U' "/home/minecraft/$selected_server" 2>/dev/null)" == "$username" ]; then
                userdel -r "$username" 2>/dev/null
                log "✓ Minecraft user $username removed" "$GREEN"
            fi
        fi
    done
    
    # 6. Remove server folder
    log "Removing server files..." "$YELLOW"
    rm -rf "/home/minecraft/$selected_server"
    
    # 7. Clean up any remaining references
    log "Cleaning up..." "$YELLOW"
    sed -i "\|/home/minecraft/$selected_server|d" /etc/fstab
    
    log "✓ Server $selected_server has been completely removed!" "$GREEN"
    
    # Ask if want to remove SSH jail config if no servers left
    if [ -z "$(ls -A /home/minecraft)" ]; then
        log "No servers left. Remove SFTP jail configuration? [y/N]" "$BLUE"
        read -r remove_jail
        if [[ "$remove_jail" =~ ^[Yy]$ ]]; then
            sed -i '/# SFTP Jail Configuration/,/PasswordAuthentication yes/d' /etc/ssh/sshd_config
            systemctl restart sshd
            log "✓ SFTP jail configuration removed" "$GREEN"
        fi
    fi
}

# Fungsi untuk menampilkan menu utama
show_main_menu() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════${NC}"
    log "MAIN MENU" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo "  1) Install new Minecraft server(s)"
    echo "  2) Uninstall existing server"
    echo "  3) List all servers"
    echo "  4) Show SFTP users"
    echo "  5) Exit"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    log "Pilihan (1-5):" "$BLUE"
    read -r menu_choice
    
    case $menu_choice in
        1) install_new_servers ;;
        2) uninstall_server ;;
        3) list_all_servers ;;
        4) list_sftp_users ;;
        5) exit 0 ;;
        *) log "Pilihan tidak valid!" "$RED"; sleep 2; show_main_menu ;;
    esac
}

# Fungsi untuk list all servers
list_all_servers() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════${NC}"
    log "ALL SERVERS" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    local found=0
    for dir in /home/minecraft/*; do
        if [ -d "$dir" ] && [ -f "$dir/bedrock_server" ]; then
            server_name=$(basename "$dir")
            found=1
            
            # Get service status
            if systemctl is-active --quiet "$server_name.service" 2>/dev/null; then
                status="${GREEN}● RUNNING${NC}"
            else
                status="${RED}○ STOPPED${NC}"
            fi
            
            # Get port from server.properties
            port=$(grep "^server-port=" "$dir/server.properties" 2>/dev/null | cut -d'=' -f2)
            
            # Get owner user
            owner=$(stat -c '%U' "$dir" 2>/dev/null)
            
            # Get SFTP users accessing this server
            sftp_access=""
            for user in $(getent group sftp-users | cut -d: -f4 | tr ',' ' '); do
                if [ -d "$SFTP_JAIL_PATH/$user" ]; then
                    if mount | grep -q "$SFTP_JAIL_PATH/$user.*$server_name"; then
                        sftp_access+="$user, "
                    fi
                fi
            done
            sftp_access=${sftp_access%, }
            [ -z "$sftp_access" ] && sftp_access="none"
            
            echo -e "\n${PURPLE}📁 $server_name${NC}"
            echo -e "  Status  : $status"
            echo -e "  Port    : $port"
            echo -e "  Owner   : $owner"
            echo -e "  SFTP    : $sftp_access"
            echo -e "  Path    : $dir"
        fi
    done
    
    if [ $found -eq 0 ]; then
        log "❌ No Minecraft servers found" "$YELLOW"
    fi
    
    echo
    log "Press Enter to continue..." "$BLUE"
    read -r
    show_main_menu
}

# Fungsi untuk list SFTP users
list_sftp_users() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════${NC}"
    log "SFTP USERS" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    local found=0
    while IFS=: read -r username _ uid gid desc home shell; do
        if id -nG "$username" | grep -qw "sftp-users"; then
            found=1
            
            # Get jail info
            if [ -d "$SFTP_JAIL_PATH/$username" ]; then
                jail_path="$SFTP_JAIL_PATH/$username"
                # Find which server they can access
                server_access=$(mount | grep "$jail_path" | awk '{print $3}' | grep -o '[^/]*$' | head -1)
                [ -z "$server_access" ] && server_access="none"
            else
                server_access="jail not set"
            fi
            
            echo -e "\n${PURPLE}👤 $username${NC}"
            echo -e "  UID      : $uid"
            echo -e "  Home     : $home"
            echo -e "  Shell    : $shell"
            echo -e "  Server   : $server_access"
            echo -e "  Jail     : $SFTP_JAIL_PATH/$username"
        fi
    done < /etc/passwd
    
    if [ $found -eq 0 ]; then
        log "❌ No SFTP users found" "$YELLOW"
    fi
    
    echo
    log "Press Enter to continue..." "$BLUE"
    read -r
    show_main_menu
}

# Fungsi untuk install new servers (modified from main)
install_new_servers() {
    # Panggil fungsi-fungsi instalasi dari script sebelumnya
    # Tapi dengan tambahan SFTP user setup
    
    log "Starting new server installation..." "$YELLOW"
    
    # Resource checks
    check_resources
    check_dependencies
    
    # Setup SFTP jail environment
    setup_sftp_jail
    
    # Setup users and folders
    setup_user_and_folders
    
    # Array untuk config dan users
    declare -a server_configs=()
    declare -a sftp_users=()
    
    # Loop config server
    for i in $(seq 1 $jumlah_server); do
        if get_server_config $i; then
            # Setup SFTP user for this server
            setup_user_with_password $i "$folder_name"
        fi
    done
    
    # Cek ada server yang dikonfigurasi
    [ ${#server_configs[@]} -eq 0 ] && error_exit "Tidak ada server yang dikonfigurasi"
    
    # Pilih versi
    select_version
    
    # Setup semua server
    local success_count=0
    for config in "${server_configs[@]}"; do
        if setup_server "$config"; then
            ((success_count++))
        fi
    done
    
    [ $success_count -eq 0 ] && error_exit "Tidak ada server yang berhasil diinstall"
    
    # Buat systemd
    for config in "${server_configs[@]}"; do
        create_systemd "$config"
    done
    
    # Enable services
    for config in "${server_configs[@]}"; do
        enable_service "$config"
    done
    
    # Tampilkan SFTP credentials
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    log "SFTP ACCESS CREDENTIALS" "$PURPLE"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    
    local ip_address=$(hostname -I | awk '{print $1}')
    for user_info in "${sftp_users[@]}"; do
        IFS='|' read -r username password server_folder <<< "$user_info"
        
        echo -e "\n${CYAN}Server: $server_folder${NC}"
        echo -e "  Username : $username"
        echo -e "  Password : ${YELLOW}$password${NC}"
        echo -e "  Command  : sftp $username@$ip_address"
        echo -e "  URL      : sftp://$username@$ip_address:$SSH_PORT"
        echo -e "  Jail     : $SFTP_JAIL_PATH/$username"
        echo -e "  Access   : /home/$username (maps to server folder)"
    done
    
    echo -e "\n${RED}⚠ IMPORTANT: Save these passwords! They won't be shown again.${NC}"
    
    # Tanya start sekarang
    log "\nStart semua server sekarang? [y/N]" "$BLUE"
    read -r start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_all_servers
    fi
    
    # Tampilkan summary
    show_summary
    
    log "\nTekan Enter untuk kembali ke menu..." "$GREEN"
    read -r
    show_main_menu
}

# Sisipkan fungsi-fungsi dari script sebelumnya di sini
# (check_resources, check_dependencies, setup_user_and_folders, 
#  validate_port, check_port, sanitize_folder_name, get_server_config,
#  select_version, setup_server, create_systemd, enable_service,
#  start_all_servers, show_summary)

# [Sisipkan semua fungsi dari script v4.0 di sini...]
# Untuk keperluan contoh, saya hanya menampilkan fungsi baru
# Dalam implementasi nyata, semua fungsi v4.0 harus disertakan

# Fungsi utama yang dimodifikasi
main() {
    show_banner
    
    # Cek root
    if [ "$EUID" -ne 0 ]; then 
        error_exit "Script harus dijalankan sebagai root"
    fi
    
    # Tampilkan menu utama
    show_main_menu
}

# Run main
main
