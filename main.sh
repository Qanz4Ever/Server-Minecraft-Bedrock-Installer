#!/bin/bash

# Minecraft Bedrock Server Auto Installer v5.6 - Enterprise Edition
# Fixed SFTP error + Simplified directory structure

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Konfigurasi global
SCRIPT_VERSION="5.6"
MIN_DISK_SPACE=1024  # MB
MIN_RAM_PER_SERVER=512  # MB
SSH_PORT=22
BASE_PATH="/home/minecraft"

# Language variables
LANG_EN=0
LANG_ID=1
CURRENT_LANG=$LANG_EN

# Fungsi untuk clear screen dengan banner
clear_screen() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Minecraft Bedrock Server Auto Installer v$SCRIPT_VERSION        ║"
    echo "║         (Enterprise Edition - Fixed SFTP)               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Fungsi untuk mendapatkan teks berdasarkan bahasa
t() {
    local en_text=$1
    local id_text=$2
    
    if [ "$CURRENT_LANG" -eq "$LANG_ID" ]; then
        echo "$id_text"
    else
        echo "$en_text"
    fi
}

# Fungsi untuk logging dengan timestamp
log() {
    local message=$1
    local color=${2:-$GREEN}
    local timestamp=$(date '+%H:%M:%S')
    echo -e "${color}[$timestamp] $message${NC}"
}

# Fungsi untuk success message
success() {
    log "✅ $1" "$GREEN"
}

# Fungsi untuk warning message
warning() {
    log "⚠️ $1" "$YELLOW"
}

# Fungsi untuk error message
error() {
    log "❌ $1" "$RED"
}

# Fungsi untuk info message
info() {
    log "ℹ️ $1" "$BLUE"
}

# Fungsi untuk error handling
error_exit() {
    error "$1"
    exit 1
}

# Fungsi untuk memilih bahasa
select_language() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo "  Select Language / Pilih Bahasa"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo "  0) English (Default)"
    echo "  1) Indonesian"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "Choice / Pilihan (0-1):" "$BLUE"
    read -r lang_choice
    
    case $lang_choice in
        1) CURRENT_LANG=$LANG_ID
           success "Bahasa Indonesia dipilih"
           ;;
        *) CURRENT_LANG=$LANG_EN
           success "English selected"
           ;;
    esac
    sleep 1
}

# Fungsi untuk mengecek system resources
check_resources() {
    info "$(t "Checking system resources..." "Memeriksa resources sistem...")"
    
    local available_disk=$(df -m /home | awk 'NR==2 {print $4}')
    if [ "$available_disk" -lt "$MIN_DISK_SPACE" ]; then
        error_exit "$(t "Insufficient disk space! Minimum ${MIN_DISK_SPACE}MB, available ${available_disk}MB" "Disk space tidak cukup! Minimal ${MIN_DISK_SPACE}MB, tersedia ${available_disk}MB")"
    fi
    success "$(t "Disk space: ${available_disk}MB available" "Disk space: ${available_disk}MB tersedia")"
    
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    success "$(t "Total RAM: ${total_ram}MB" "Total RAM: ${total_ram}MB")"
    
    if [ ! -f /etc/debian_version ]; then
        warning "$(t "This script is optimized for Debian/Ubuntu" "Script ini dioptimalkan untuk Debian/Ubuntu")"
    fi
}

# Fungsi untuk mengecek dan install dependencies
check_dependencies() {
    info "$(t "Checking dependencies..." "Memeriksa dependencies...")"
    
    local deps=("unzip" "curl" "tmux" "systemctl" "chmod" "lsof" "ufw" "wget" "bc" "openssh-server" "openssl")
    local install_packages=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            if [[ $dep == "openssh-server" ]]; then
                if ! systemctl list-unit-files | grep -q ssh; then
                    install_packages+=($dep)
                else
                    success "sshd $(t "available" "tersedia")"
                    continue
                fi
            else
                warning "$dep $(t "not found" "tidak ditemukan")"
                install_packages+=($dep)
            fi
        else
            success "$dep $(t "available" "tersedia")"
        fi
    done
    
    if [ ${#install_packages[@]} -gt 0 ]; then
        info "$(t "Installing: ${install_packages[*]}" "Menginstall: ${install_packages[*]}")"
        apt update && apt install -y ${install_packages[*]} || error_exit "$(t "Failed to install dependencies" "Gagal install dependencies")"
        success "$(t "Dependencies installed" "Dependencies terinstall")"
    fi
    
    # Generate SSH host keys if missing
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        info "$(t "Generating SSH host keys..." "Membuat SSH host keys...")"
        dpkg-reconfigure openssh-server
        systemctl restart sshd
    fi
    
    configure_ssh
}

# Fungsi untuk configure SSH
configure_ssh() {
    info "$(t "Configuring SSH for proper SFTP/SSH access..." "Mengkonfigurasi SSH untuk akses SFTP/SSH...")"
    
    local sshd_config="/etc/ssh/sshd_config"
    local backup="/etc/ssh/sshd_config.backup.$(date +%Y%m%d)"
    
    # Backup
    cp "$sshd_config" "$backup"
    
    # Ensure password authentication is enabled
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
    
    # Disable root login
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
    
    # Enable SFTP internal
    if ! grep -q "Subsystem sftp internal-sftp" "$sshd_config"; then
        echo "Subsystem sftp internal-sftp" >> "$sshd_config"
    fi
    
    systemctl restart sshd
    success "$(t "SSH configured" "SSH dikonfigurasi")"
}

# Fungsi untuk generate random password
generate_password() {
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9!@#$%^&*' | fold -w 16 | head -n 1
}

# Fungsi untuk setup user dengan akses SSH/SFTP yang benar
setup_minecraft_user() {
    local username=$1
    local password=$2
    local server_path="$BASE_PATH/$username"
    
    info "$(t "Setting up user:" "Membuat user:") $username"
    
    # Create user if not exists
    if ! id "$username" &>/dev/null; then
        useradd -m -d "/home/$username" -s /bin/bash "$username"
        success "$(t "User" "User") $username $(t "created" "dibuat")"
    else
        warning "$(t "User" "User") $username $(t "already exists" "sudah ada")"
        pkill -u "$username" 2>/dev/null
    fi
    
    # Set password
    echo "$username:$password" | chpasswd
    success "$(t "Password set for" "Password diatur untuk") $username"
    
    # Remove any existing bind mounts
    umount "/home/$username/minecraft" 2>/dev/null
    sed -i "\|/home/$username/minecraft|d" /etc/fstab
    
    # Create minecraft directory in user home
    mkdir -p "/home/$username/minecraft"
    
    # Bind mount the server folder to user's minecraft directory
    if ! grep -q "/home/$username/minecraft" /etc/fstab; then
        echo "$server_path /home/$username/minecraft none bind 0 0" >> /etc/fstab
    fi
    
    # Mount it
    mount --bind "$server_path" "/home/$username/minecraft" 2>/dev/null
    
    # Create symlink directly in home
    ln -sf "/home/$username/minecraft" "/home/$username/server"
    
    # Set proper ownership
    chown -R "$username:$username" "/home/$username"
    chmod 755 "/home/$username"
    
    # FIXED: .bashrc dengan conditional untuk interactive shell saja
    cat > "/home/$username/.bashrc" << 'EOF'
# Only run for interactive shell (SSH), not for SFTP
if [[ $- == *i* ]]; then
    if [ -d "$HOME/minecraft" ]; then
        cd "$HOME/minecraft"
        echo "Welcome to Minecraft Server - $(basename $(pwd))"
        echo "You are in your server directory. Files available:"
        ls -F --color=auto
    fi
fi

# Simple prompt
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\W\[\e[0m\]\$ '

# Aliases
alias ll='ls -la'
alias la='ls -a'
alias l='ls -CF'

# No dangerous commands
alias sudo='echo "sudo not allowed"'
alias apt='echo "apt not allowed"'
alias systemctl='echo "systemctl not allowed"'
alias service='echo "service not allowed"'
alias dpkg='echo "dpkg not allowed"'
EOF
    
    # Set proper permissions for .bashrc
    chown "$username:$username" "/home/$username/.bashrc"
    
    # Ensure SSH directory exists for future key-based auth
    mkdir -p "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    chown "$username:$username" "/home/$username/.ssh"
    
    # Add user to appropriate groups
    usermod -aG "$username" "$username"
    
    success "$(t "User" "User") $username $(t "setup complete" "setup selesai")"
}

# Fungsi untuk setup user dengan pilihan password
setup_user_with_password() {
    local server_index=$1
    local username="mcserver$server_index"
    
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "$(t "User Configuration for Server #$server_index" "Konfigurasi User untuk Server #$server_index")" "$PURPLE"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    info "$(t "Username:" "Username:") $username"
    
    info "$(t "Choose password method:" "Pilih metode password:")" "$BLUE"
    echo "  1) $(t "Generate random password (recommended)" "Generate random password (disarankan)")"
    echo "  2) $(t "Enter password manually" "Masukkan password manual")"
    info "$(t "Choice (default: 1):" "Pilihan (default: 1):")" "$BLUE"
    read -r password_choice
    
    local user_password
    case $password_choice in
        2)
            while true; do
                info "$(t "Enter password (min 8 characters):" "Masukkan password (min 8 karakter):")" "$BLUE"
                read -s user_password
                echo
                info "$(t "Confirm password:" "Konfirmasi password:")" "$BLUE"
                read -s user_password_confirm
                echo
                
                if [ "$user_password" != "$user_password_confirm" ]; then
                    error "$(t "Passwords do not match!" "Password tidak cocok!")"
                elif [ ${#user_password} -lt 8 ]; then
                    error "$(t "Password minimum 8 characters!" "Password minimal 8 karakter!")"
                else
                    break
                fi
            done
            ;;
        *)
            user_password=$(generate_password)
            success "$(t "Random password generated" "Random password dibuat")"
            ;;
    esac
    
    # Save user info
    server_users+=("$username|$user_password")
    
    # Setup user
    setup_minecraft_user "$username" "$user_password"
}

# Fungsi untuk validasi port
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# Fungsi untuk cek port availability
check_port() {
    local port_var=$1
    local port_value=$2
    local server_index=$3
    
    if ! validate_port "$port_value"; then
        error "$(t "Port" "Port") $port_value $(t "invalid (1024-65535)" "tidak valid (1024-65535)")"
        return 1
    fi
    
    if lsof -i:"$port_value" >/dev/null 2>&1; then
        warning "$(t "Port" "Port") $port_value $(t "already in use" "sudah dipakai")"
        
        local new_port=$port_value
        local max_attempts=100
        local attempt=0
        
        while lsof -i:"$new_port" >/dev/null 2>&1 && [ $attempt -lt $max_attempts ]; do
            new_port=$((new_port + 1))
            [ $new_port -gt 65535 ] && new_port=1024
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -eq $max_attempts ]; then
            error "$(t "No available port found" "Tidak ada port kosong")"
            return 1
        fi
        
        success "$(t "Using port" "Menggunakan port") $new_port"
        eval "$port_var=$new_port"
    else
        success "$(t "Port" "Port") $port_value $(t "available" "tersedia")"
    fi
    return 0
}

# Fungsi untuk sanitasi nama folder (not used much now since we use username directly)
sanitize_folder_name() {
    local name=$1
    echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-'
}

# Fungsi untuk setup user dan folders
setup_user_and_folders() {
    info "$(t "Setting up users and folders..." "Membuat user dan folder...")"
    
    while true; do
        info "$(t "Enter number of servers (1-10):" "Masukkan jumlah server (1-10):")" "$BLUE"
        read -r jumlah_server
        if [[ "$jumlah_server" =~ ^[0-9]+$ ]] && [ "$jumlah_server" -ge 1 ] && [ "$jumlah_server" -le 10 ]; then
            break
        else
            warning "$(t "Please enter a number between 1-10" "Masukkan angka 1-10")"
        fi
    done
    
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local min_ram_needed=$((jumlah_server * MIN_RAM_PER_SERVER))
    if [ "$total_ram" -lt "$min_ram_needed" ]; then
        warning "$(t "RAM might be insufficient: ${total_ram}MB total, minimum ${min_ram_needed}MB needed" "RAM mungkin tidak cukup: ${total_ram}MB total, minimal ${min_ram_needed}MB diperlukan")"
        info "$(t "Continue? [y/N]" "Lanjutkan? [y/N]")" "$BLUE"
        read -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    mkdir -p "$BASE_PATH"
    success "$(t "Folder structure ready" "Struktur folder siap")"
}

# Fungsi untuk input konfigurasi server
get_server_config() {
    local server_index=$1
    local username="mcserver$server_index"
    
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "$(t "Configuration for Server #$server_index" "Konfigurasi Server #$server_index")" "$PURPLE"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Check if server directory already exists
    if [ -d "$BASE_PATH/$username" ]; then
        warning "$(t "Server directory for" "Direktori server untuk") $username $(t "already exists" "sudah ada")"
        info "$(t "Choose: [1] overwrite [2] skip" "Pilih: [1] overwrite [2] skip")" "$BLUE"
        read -r choice
        case $choice in
            1)
                warning "$(t "Overwriting server..." "Overwrite server...")"
                rm -rf "$BASE_PATH/$username"
                ;;
            2)
                return 1
                ;;
            *)
                error "$(t "Invalid choice, skipping" "Pilihan tidak valid, skip")"
                return 1
                ;;
        esac
    fi
    
    info "$(t "Server name (default: Server$server_index):" "Nama server (default: Server$server_index):")" "$BLUE"
    read -r server_name
    [ -z "$server_name" ] && server_name="Server$server_index"
    
    info "$(t "World name (default: world):" "Nama world (default: world):")" "$BLUE"
    read -r level_name
    [ -z "$level_name" ] && level_name="world"
    
    info "$(t "Seed (leave empty for random):" "Seed (kosongkan untuk random):")" "$BLUE"
    read -r level_seed
    
    local default_port=$((19132 + server_index - 1))
    while true; do
        info "$(t "Server port (default: $default_port):" "Port server (default: $default_port):")" "$BLUE"
        read -r server_port
        [ -z "$server_port" ] && server_port=$default_port
        
        if validate_port "$server_port"; then
            break
        else
            warning "$(t "Port must be 1024-65535" "Port harus 1024-65535")"
        fi
    done
    
    check_port server_port "$server_port" $server_index || return 1
    
    local server_portv6=$((server_port + 1))
    
    info "$(t "Choose gamemode:" "Pilih gamemode:")" "$BLUE"
    echo "  0) survival"
    echo "  1) creative"
    echo "  2) adventure"
    info "$(t "Choice (default: 0):" "Pilihan (default: 0):")" "$BLUE"
    read -r gamemode_choice
    case $gamemode_choice in
        1) gamemode="creative" ;;
        2) gamemode="adventure" ;;
        *) gamemode="survival" ;;
    esac
    
    info "$(t "Choose difficulty:" "Pilih difficulty:")" "$BLUE"
    echo "  0) peaceful"
    echo "  1) easy"
    echo "  2) normal"
    echo "  3) hard"
    info "$(t "Choice (default: 2):" "Pilihan (default: 2):")" "$BLUE"
    read -r difficulty_choice
    case $difficulty_choice in
        0) difficulty="peaceful" ;;
        1) difficulty="easy" ;;
        3) difficulty="hard" ;;
        *) difficulty="normal" ;;
    esac
    
    info "$(t "Enable cheats? [0] false [1] true (default: 0):" "Aktifkan cheats? [0] false [1] true (default: 0):")" "$BLUE"
    read -r cheats_choice
    allow_cheats=$([ "$cheats_choice" == "1" ] && echo "true" || echo "false")
    
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "$server_port/udp" 2>/dev/null
            success "$(t "Firewall port" "Firewall port") $server_port/udp $(t "opened" "dibuka")"
        fi
    fi
    
    server_configs+=("$username|$server_name|$level_name|$level_seed|$server_port|$server_portv6|$gamemode|$difficulty|$allow_cheats")
    
    return 0
}

# Fungsi untuk memilih versi server
select_version() {
    info "$(t "Selecting server version..." "Memilih versi server...")"
    
    while true; do
        info "$(t "Enter version (example: 1.21.114.1) or 'latest':" "Masukkan versi (contoh: 1.21.114.1) atau 'latest':")" "$BLUE"
        read -r version
        
        if [ "$version" == "latest" ]; then
            info "$(t "Looking for latest version..." "Mencari versi terbaru...")"
            
            latest_url=$(curl -A "Mozilla/5.0" -s "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links" | 
                        grep -o '"downloadUrl":"[^"]*serverBedrockLinux[^"]*"' | 
                        head -1 | 
                        cut -d'"' -f4)
            
            if [ -n "$latest_url" ]; then
                version=$(echo "$latest_url" | grep -o 'bedrock-server-[0-9.]*\.zip' | sed 's/bedrock-server-//;s/\.zip//')
                success "$(t "Latest version:" "Versi terbaru:") $version"
                download_url="$latest_url"
                break
            else
                error "$(t "Failed to get latest version" "Gagal dapat versi terbaru")"
                continue
            fi
        else
            download_url="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-$version.zip"
        fi
        
        info "$(t "Checking version" "Memeriksa versi") $version..."
        
        if curl -A "Mozilla/5.0" --output /dev/null --silent --head --fail --connect-timeout 10 "$download_url"; then
            success "$(t "Version" "Versi") $version $(t "available" "tersedia")"
            break
        else
            error "$(t "Version" "Versi") $version $(t "not found" "tidak ditemukan")"
        fi
    done
    
    DOWNLOAD_URL=$download_url
}

# Fungsi untuk download dan setup server
setup_server() {
    local config=$1
    IFS='|' read -r username server_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    local server_path="$BASE_PATH/$username"
    
    info "$(t "Setting up server for" "Setup server untuk") $username"
    
    cd "$BASE_PATH" || error_exit "$(t "Cannot cd to" "Tidak bisa masuk ke") $BASE_PATH"
    
    mkdir -p "$username"
    cd "$username" || error_exit "$(t "Cannot cd to" "Tidak bisa masuk ke") $username"
    
    [ -f "server.properties" ] && cp "server.properties" "server.properties.backup.$(date +%Y%m%d-%H%M%S)"
    
    if [ ! -f "bedrock_server" ]; then
        info "$(t "Downloading server files..." "Mendownload file server...")"
        
        local max_retries=3
        local retry=0
        while [ $retry -lt $max_retries ]; do
            wget --user-agent="Mozilla/5.0" \
                 -O bedrock-server.zip \
                 --timeout=30 \
                 --tries=3 \
                 "$DOWNLOAD_URL" && break
            
            retry=$((retry + 1))
            [ $retry -lt $max_retries ] && warning "$(t "Retry" "Ulang") $retry/$max_retries..."
        done
        
        if [ ! -f "bedrock-server.zip" ]; then
            error "$(t "Download failed after" "Download gagal setelah") $max_retries $(t "attempts" "percobaan")"
            return 1
        fi
        
        local file_size=$(stat -c%s "bedrock-server.zip" 2>/dev/null || stat -f%z "bedrock-server.zip" 2>/dev/null)
        if [ -z "$file_size" ] || [ "$file_size" -lt 50000000 ]; then
            error "$(t "File corrupted (size:" "File corrupted (ukuran:") $file_size $(t "bytes)" "bytes)")"
            rm -f "bedrock-server.zip"
            return 1
        fi
        
        info "$(t "Extracting..." "Mengekstrak...")"
        unzip -o bedrock-server.zip || {
            error "$(t "Extract failed" "Ekstrak gagal")"
            return 1
        }
        rm bedrock-server.zip
    else
        success "$(t "Server files already exist" "File server sudah ada")"
    fi
    
    chmod +x bedrock_server
    
    info "$(t "Creating server.properties..." "Membuat server.properties...")"
    cat > server.properties << EOF
# Minecraft Bedrock Server Properties
server-name=$server_name
gamemode=$gamemode
force-gamemode=false
difficulty=$difficulty
allow-cheats=$allow_cheats
max-players=99999
online-mode=true
allow-list=false
server-port=$server_port
server-portv6=$server_portv6
enable-lan-visibility=true
view-distance=10
tick-distance=4
player-idle-timeout=120
max-threads=8
level-name=$level_name
level-seed=$level_seed
default-player-permission-level=member
texturepack-required=false
content-log-file-enabled=false
compression-threshold=1
compression-algorithm=zlib
EOF
    
    success "$(t "Server for" "Server untuk") $username $(t "ready" "siap")"
    return 0
}

# Fungsi untuk membuat systemd service
create_systemd() {
    local config=$1
    IFS='|' read -r username server_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    
    local service_name="$username.service"
    local service_file="/etc/systemd/system/$service_name"
    local server_path="$BASE_PATH/$username"
    
    info "$(t "Creating systemd service for" "Membuat systemd service untuk") $username..."
    
    # Verify user exists
    if ! id "$username" &>/dev/null; then
        error "$(t "User" "User") $username $(t "not found! Creating user..." "tidak ditemukan! Membuat user...")"
        temp_pass=$(generate_password)
        setup_minecraft_user "$username" "$temp_pass"
    fi
    
    # Set proper permissions
    chown -R "$username:$username" "$server_path"
    chmod -R 755 "$server_path"
    
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local ram_per_server=$((total_ram / jumlah_server))
    [ $ram_per_server -gt 2048 ] && ram_per_server=2048
    
    cat > "$service_file" << EOF
[Unit]
Description=Minecraft Bedrock Server - $server_name
After=network.target
StartLimitInterval=60
StartLimitBurst=3

[Service]
Type=forking
User=$username
Group=$username
Environment=HOME=$server_path
Environment=USER=$username
WorkingDirectory=$server_path
ExecStart=/usr/bin/tmux new-session -d -s $username -c $server_path '$server_path/bedrock_server'
ExecStop=/usr/bin/tmux kill-session -t $username
ExecReload=/usr/bin/tmux send-keys -t $username 'reload' C-m
Restart=always
RestartSec=10
Nice=10
CPUQuota=80%
MemoryLimit=${ram_per_server}M
LimitNOFILE=65535
StandardInput=null
StandardOutput=append:$server_path/server.log
StandardError=append:$server_path/error.log
SuccessExitStatus=0 1
RestartPreventExitStatus=255

[Install]
WantedBy=multi-user.target
EOF
    
    if [ -f "$service_file" ]; then
        success "$(t "Service" "Service") $service_name $(t "created" "dibuat")"
        systemd-analyze verify "$service_file" 2>/dev/null || warning "$(t "Service file has warnings" "File service memiliki peringatan")"
    else
        error "$(t "Failed to create service file" "Gagal membuat file service")"
    fi
}

# Fungsi untuk enable service
enable_service() {
    local config=$1
    IFS='|' read -r username server_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    
    local service_name="$username.service"
    
    info "$(t "Enabling service" "Mengaktifkan service") $service_name..."
    systemctl daemon-reload
    systemctl enable "$service_name" || error "$(t "Failed to enable service" "Gagal enable service")"
    success "$(t "Service enabled" "Service diaktifkan")"
}

# Fungsi untuk start semua server dengan delay
start_all_servers() {
    info "$(t "Starting all servers..." "Menjalankan semua server...")"
    
    local index=1
    for config in "${server_configs[@]}"; do
        IFS='|' read -r username server_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
        
        info "$(t "Starting" "Menjalankan") $username ($(t "port" "port") $server_port)..."
        systemctl start "$username.service"
        
        sleep 3
        if systemctl is-active --quiet "$username.service"; then
            success "$username $(t "running" "berjalan")"
            
            # Check tmux session
            if tmux has-session -t "$username" 2>/dev/null; then
                success "Tmux session: $username"
            fi
        else
            error "$username $(t "failed to start" "gagal start")"
            warning "$(t "Check logs:" "Cek log:") journalctl -u $username.service -n 20"
            journalctl -u "$username.service" --no-pager -n 5
        fi
        
        if [ $index -lt ${#server_configs[@]} ]; then
            info "$(t "Waiting 5 seconds..." "Menunggu 5 detik...")"
            sleep 5
        fi
        
        ((index++))
    done
}

# Fungsi untuk cleanup total - menghapus SEMUA
cleanup_total() {
    clear_screen
    echo -e "\n${RED}══════════════════════════════════════════════════════════${NC}"
    error "⚠️  $(t "TOTAL CLEANUP - DELETING EVERYTHING!" "TOTAL CLEANUP - MENGHAPUS SEMUA!")  ⚠️"
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    error "$(t "This will delete:" "Ini akan menghapus:")"
    error "  • $(t "All Minecraft servers" "Semua Minecraft servers")"
    error "  • $(t "All users (mcserver*)" "Semua user (mcserver*)")"
    error "  • $(t "All systemd services" "Semua systemd services")"
    error "  • $(t "All bind mounts" "Semua bind mounts")"
    error "  • $(t "All SSH configurations" "Semua konfigurasi SSH")"
    echo
    warning "$(t "Type 'TOTAL-DELETE' to confirm:" "Ketik 'TOTAL-DELETE' untuk konfirmasi:")"
    read -r confirmation
    
    if [ "$confirmation" != "TOTAL-DELETE" ]; then
        warning "$(t "Total cleanup cancelled" "Total cleanup dibatalkan")"
        cleanup_menu
        return
    fi
    
    info "$(t "Starting total cleanup..." "Memulai total cleanup...")"
    
    # Stop all services
    info "$(t "Stopping all services..." "Menghentikan semua service...")"
    for service in /etc/systemd/system/mcserver*.service; do
        if [ -f "$service" ]; then
            service_name=$(basename "$service")
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service"
            success "$(t "Removed service:" "Menghapus service:") $service_name"
        fi
    done
    
    # Kill all tmux sessions
    info "$(t "Killing tmux sessions..." "Mematikan tmux sessions...")"
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        tmux kill-session -t "$user" 2>/dev/null
    done
    
    # Remove all bind mounts from fstab
    info "$(t "Cleaning fstab..." "Membersihkan fstab...")"
    sed -i "\|$BASE_PATH|d" /etc/fstab
    sed -i "\|/home/mcserver|d" /etc/fstab
    
    # Unmount all bind mounts
    info "$(t "Unmounting all bind mounts..." "Unmount semua bind mounts...")"
    mount | grep "/home/mcserver" | awk '{print $3}' | xargs -r umount -f 2>/dev/null
    
    # Remove all Minecraft users
    info "$(t "Removing all Minecraft users..." "Menghapus semua Minecraft users...")"
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        pkill -u "$user" 2>/dev/null
        userdel -r "$user" 2>/dev/null
        success "$(t "Removed user:" "Menghapus user:") $user"
    done
    
    # Remove Minecraft directories
    info "$(t "Removing Minecraft directories..." "Menghapus direktori Minecraft...")"
    rm -rf "$BASE_PATH"
    
    # Clean SSH config from any custom settings
    info "$(t "Cleaning SSH configuration..." "Membersihkan konfigurasi SSH...")"
    local sshd_config="/etc/ssh/sshd_config"
    sed -i '/# Minecraft user configurations/,/^$/d' "$sshd_config"
    
    # Restore default SSH settings
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
    
    systemctl daemon-reload
    systemctl restart sshd
    
    success "✅ $(t "Total cleanup complete! Everything has been removed." "Total cleanup selesai! Semua telah dihapus.")"
    info "$(t "System returned to pre-installation state." "Sistem kembali ke keadaan sebelum instalasi.")"
    
    read -p "$(t "Press Enter to continue..." "Tekan Enter untuk melanjutkan...")"
    show_main_menu
}

# Fungsi untuk cleanup menu
cleanup_menu() {
    clear_screen
    echo -e "\n${RED}══════════════════════════════════════════════════════════${NC}"
    info "$(t "CLEANUP MENU" "MENU CLEANUP")" "$RED"
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    
    echo "  1) $(t "Clean specific server" "Bersihkan server tertentu")"
    echo "  2) $(t "Clean ALL servers and users (TOTAL CLEANUP)" "Bersihkan SEMUA server dan user (TOTAL CLEANUP)")"
    echo "  3) $(t "Clean orphaned users (no server)" "Bersihkan user yatim (tanpa server)")"
    echo "  4) $(t "Back to main menu" "Kembali ke menu utama")"
    
    info "$(t "Choice (1-4):" "Pilihan (1-4):")" "$BLUE"
    read -r cleanup_choice
    
    case $cleanup_choice in
        1) cleanup_specific_server ;;
        2) cleanup_total ;;
        3) cleanup_orphaned_users ;;
        4) show_main_menu ;;
        *) error "$(t "Invalid choice!" "Pilihan tidak valid!")"; sleep 2; cleanup_menu ;;
    esac
}

# Fungsi untuk cleanup server spesifik
cleanup_specific_server() {
    echo -e "\n${YELLOW}$(t "Available servers:" "Server tersedia:")${NC}"
    local servers=()
    local i=1
    
    for dir in "$BASE_PATH"/*; do
        if [ -d "$dir" ]; then
            username=$(basename "$dir")
            if [[ "$username" == mcserver* ]]; then
                servers+=("$username")
                echo "  $i) $username"
                ((i++))
            fi
        fi
    done
    
    if [ ${#servers[@]} -eq 0 ]; then
        error "$(t "No servers found" "Tidak ada server ditemukan")"
        sleep 2
        cleanup_menu
        return
    fi
    
    echo
    info "$(t "Choose server to clean (number):" "Pilih server yang akan dibersihkan (nomor):")" "$BLUE"
    read -r server_choice
    
    if ! [[ "$server_choice" =~ ^[0-9]+$ ]] || [ "$server_choice" -lt 1 ] || [ "$server_choice" -gt ${#servers[@]} ]; then
        error "$(t "Invalid choice" "Pilihan tidak valid")"
        cleanup_menu
        return
    fi
    
    local selected_user="${servers[$((server_choice-1))]}"
    
    echo
    error "⚠️ $(t "WARNING! Deleting server:" "PERINGATAN! Menghapus server:") $selected_user"
    info "$(t "Type 'DELETE' to confirm:" "Ketik 'DELETE' untuk konfirmasi:")" "$BLUE"
    read -r confirmation
    
    if [ "$confirmation" != "DELETE" ]; then
        warning "$(t "Cleanup cancelled" "Cleanup dibatalkan")"
        cleanup_menu
        return
    fi
    
    # Stop and disable service
    systemctl stop "$selected_user.service" 2>/dev/null
    systemctl disable "$selected_user.service" 2>/dev/null
    rm -f "/etc/systemd/system/$selected_user.service"
    
    # Remove from fstab
    sed -i "\|$BASE_PATH/$selected_user|d" /etc/fstab
    
    # Kill tmux session
    tmux kill-session -t "$selected_user" 2>/dev/null
    
    # Unmount bind mounts
    umount "/home/$selected_user/minecraft" 2>/dev/null
    sed -i "\|/home/$selected_user/minecraft|d" /etc/fstab
    
    # Kill user processes
    pkill -u "$selected_user" 2>/dev/null
    
    # Remove user
    userdel -r "$selected_user" 2>/dev/null
    success "$(t "Removed user" "User dihapus") $selected_user"
    
    # Remove server folder
    rm -rf "$BASE_PATH/$selected_user"
    
    systemctl daemon-reload
    
    success "$(t "Server" "Server") $selected_user $(t "cleaned up!" "dibersihkan!")"
    sleep 2
    cleanup_menu
}

# Fungsi untuk cleanup orphaned users
cleanup_orphaned_users() {
    info "$(t "Looking for orphaned users..." "Mencari user yatim...")"
    
    local found=0
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        if [ ! -d "$BASE_PATH/$user" ]; then
            warning "$(t "Found orphaned user:" "Ditemukan user yatim:") $user"
            
            tmux kill-session -t "$user" 2>/dev/null
            umount "/home/$user/minecraft" 2>/dev/null
            sed -i "\|/home/$user|d" /etc/fstab
            pkill -u "$user" 2>/dev/null
            userdel -r "$user" 2>/dev/null
            success "$(t "Removed orphaned user" "User yatim dihapus") $user"
            found=1
        fi
    done
    
    if [ $found -eq 0 ]; then
        success "$(t "No orphaned users found" "Tidak ada user yatim ditemukan")"
    fi
    
    sleep 2
    cleanup_menu
}

# Fungsi untuk list semua server
list_all_servers() {
    clear_screen
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "$(t "ALL SERVERS" "SEMUA SERVER")" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    local found=0
    for dir in "$BASE_PATH"/*; do
        if [ -d "$dir" ]; then
            username=$(basename "$dir")
            if [[ "$username" == mcserver* ]]; then
                found=1
                
                if [ -f "$dir/bedrock_server" ]; then
                    if systemctl is-active --quiet "$username.service" 2>/dev/null; then
                        status="${GREEN}● $(t "RUNNING" "BERJALAN")${NC}"
                        pid=$(pgrep -f "bedrock_server" | head -1)
                        [ -n "$pid" ] && pid_info=" (PID: $pid)" || pid_info=""
                    else
                        status="${RED}○ $(t "STOPPED" "BERHENTI")${NC}"
                        pid_info=""
                    fi
                else
                    status="${YELLOW}○ $(t "INCOMPLETE" "TIDAK LENGKAP")${NC}"
                    pid_info=""
                fi
                
                port=$(grep "^server-port=" "$dir/server.properties" 2>/dev/null | cut -d'=' -f2)
                
                # Check tmux session
                if tmux has-session -t "$username" 2>/dev/null; then
                    tmux_info=" (tmux)"
                else
                    tmux_info=""
                fi
                
                echo -e "\n${PURPLE}📁 $username${NC}"
                echo -e "  $(t "Status" "Status")  : $status$pid_info"
                echo -e "  $(t "Port" "Port")    : ${port:-N/A}"
                echo -e "  $(t "User" "User")    : $username$tmux_info"
                echo -e "  $(t "Path" "Path")    : $dir"
            fi
        fi
    done
    
    if [ $found -eq 0 ]; then
        error "$(t "No Minecraft servers found" "Tidak ada Minecraft server ditemukan")"
    fi
    
    echo
    info "$(t "Press Enter to continue..." "Tekan Enter untuk melanjutkan...")" "$BLUE"
    read -r
    show_main_menu
}

# Fungsi untuk menampilkan menu utama
show_main_menu() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "$(t "MAIN MENU" "MENU UTAMA")" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo "  1) $(t "Install new Minecraft server(s)" "Install server Minecraft baru")"
    echo "  2) $(t "Uninstall existing server" "Uninstall server yang ada")"
    echo "  3) $(t "List all servers" "Lihat semua server")"
    echo "  4) $(t "Cleanup menu" "Menu pembersihan")"
    echo "  5) $(t "Exit" "Keluar")"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "$(t "Choice (1-5):" "Pilihan (1-5):")" "$BLUE"
    read -r menu_choice
    
    case $menu_choice in
        1) install_new_servers ;;
        2) cleanup_specific_server ;;
        3) list_all_servers ;;
        4) cleanup_menu ;;
        5) exit 0 ;;
        *) error "$(t "Invalid choice!" "Pilihan tidak valid!")"; sleep 2; show_main_menu ;;
    esac
}

# Fungsi untuk install new servers
install_new_servers() {
    clear_screen
    info "$(t "Starting new server installation..." "Memulai instalasi server baru...")"
    
    check_resources
    check_dependencies
    
    declare -a server_configs=()
    declare -a server_users=()
    
    setup_user_and_folders
    
    for i in $(seq 1 $jumlah_server); do
        if get_server_config $i; then
            setup_user_with_password $i
        fi
    done
    
    if [ ${#server_configs[@]} -eq 0 ]; then
        error_exit "$(t "No servers configured" "Tidak ada server yang dikonfigurasi")"
    fi
    
    select_version
    
    local success_count=0
    for config in "${server_configs[@]}"; do
        if setup_server "$config"; then
            ((success_count++))
        fi
    done
    
    if [ $success_count -eq 0 ]; then
        error_exit "$(t "No servers were successfully installed" "Tidak ada server yang berhasil diinstall")"
    fi
    
    # Set ownership setelah server diinstall
    for user_info in "${server_users[@]}"; do
        IFS='|' read -r username password <<< "$user_info"
        chown -R "$username:$username" "$BASE_PATH/$username"
        chmod -R 755 "$BASE_PATH/$username"
    done
    
    for config in "${server_configs[@]}"; do
        create_systemd "$config"
    done
    
    for config in "${server_configs[@]}"; do
        enable_service "$config"
    done
    
    # Display credentials
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    info "$(t "SERVER ACCESS CREDENTIALS" "KREDENSIAL AKSES SERVER")" "$PURPLE"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    
    local ip_address=$(hostname -I | awk '{print $1}')
    for user_info in "${server_users[@]}"; do
        IFS='|' read -r username password <<< "$user_info"
        
        echo -e "\n${CYAN}$(t "Server:" "Server:") $username${NC}"
        echo -e "  $(t "Username" "Username")     : $username"
        echo -e "  $(t "Password" "Password")     : ${YELLOW}$password${NC}"
        echo -e "  SSH $(t "Command" "Perintah")  : ssh $username@$ip_address -p $SSH_PORT"
        echo -e "  SFTP URL     : sftp://$username@$ip_address:$SSH_PORT"
        echo -e "  $(t "Server Path" "Path Server")  : /home/$username/minecraft/ ($(t "auto-cd on login" "auto-cd saat login"))"
    done
    
    echo -e "\n${RED}⚠ $(t "IMPORTANT: Save these passwords! They won't be shown again." "PENTING: Simpan password ini! Tidak akan ditampilkan lagi.")${NC}"
    
    info "$(t "Start all servers now? [y/N]" "Jalankan semua server sekarang? [y/N]")" "$BLUE"
    read -r start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_all_servers
    fi
    
    info "$(t "Press Enter to return to menu..." "Tekan Enter untuk kembali ke menu...")" "$GREEN"
    read -r
    show_main_menu
}

# Trap for cleanup
trap 'error "$(t "Script interrupted!" "Script terinterupsi!")"; exit 1' INT TERM

# Fungsi utama
main() {
    clear_screen
    
    if [ "$EUID" -ne 0 ]; then 
        error_exit "$(t "Script must be run as root" "Script harus dijalankan sebagai root")"
    fi
    
    select_language
    show_main_menu
}

# Run main
main
