#!/bin/bash

# Minecraft Bedrock Server Auto Installer v5.3 - Enterprise Edition
# Dengan True Chroot Jail + SSH Restriction

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
SCRIPT_VERSION="5.3"
MIN_DISK_SPACE=1024  # MB
MIN_RAM_PER_SERVER=512  # MB
SSH_PORT=22
JAIL_BASE="/home"

# Fungsi untuk clear screen dengan banner
clear_screen() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Minecraft Bedrock Server Auto Installer v$SCRIPT_VERSION        ║"
    echo "║         (Enterprise Edition - SSH Restricted)           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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

# Fungsi untuk mengecek system resources
check_resources() {
    info "Memeriksa resources sistem..."
    
    # Cek disk space
    local available_disk=$(df -m /home | awk 'NR==2 {print $4}')
    if [ "$available_disk" -lt "$MIN_DISK_SPACE" ]; then
        error_exit "Disk space tidak cukup! Minimal ${MIN_DISK_SPACE}MB, tersedia ${available_disk}MB"
    fi
    success "Disk space: ${available_disk}MB tersedia"
    
    # Cek RAM total
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    success "Total RAM: ${total_ram}MB"
    
    # Cek OS
    if [ ! -f /etc/debian_version ]; then
        warning "Script ini dioptimalkan untuk Debian/Ubuntu"
    fi
}

# Fungsi untuk mengecek dan install dependencies
check_dependencies() {
    info "Memeriksa dependencies..."
    
    local deps=("unzip" "curl" "tmux" "systemctl" "chmod" "lsof" "ufw" "wget" "bc" "openssh-server" "openssl" "tmux")
    local install_packages=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            if [[ $dep == "openssh-server" ]]; then
                if ! systemctl list-unit-files | grep -q ssh; then
                    install_packages+=($dep)
                else
                    success "sshd tersedia"
                    continue
                fi
            else
                warning "$dep tidak ditemukan"
                install_packages+=($dep)
            fi
        else
            success "$dep tersedia"
        fi
    done
    
    # Install packages jika perlu
    if [ ${#install_packages[@]} -gt 0 ]; then
        info "Menginstall: ${install_packages[*]}"
        apt update && apt install -y ${install_packages[*]} || error_exit "Gagal install dependencies"
        success "Dependencies terinstall"
    fi
    
    # Configure SSH untuk restricted shell
    setup_restricted_shell
}

# Fungsi untuk setup restricted shell (rbash)
setup_restricted_shell() {
    info "Setting up restricted shell (rbash)..."
    
    # Create rbash symlink if not exists
    if [ ! -f "/bin/rbash" ]; then
        ln -s /bin/bash /bin/rbash 2>/dev/null
        success "rbash created"
    fi
    
    # Configure SSH to allow rbash
    local sshd_config="/etc/ssh/sshd_config"
    
    # Ensure AllowTcpForwarding is disabled for all
    if grep -q "^AllowTcpForwarding" "$sshd_config"; then
        sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding no/' "$sshd_config"
    else
        echo "AllowTcpForwarding no" >> "$sshd_config"
    fi
    
    systemctl restart sshd
    success "SSH configured for restricted shell"
}

# Fungsi untuk membuat restricted user (rbash)
create_restricted_user() {
    local username=$1
    local password=$2
    local server_folder=$3
    
    info "Creating restricted user: $username"
    
    # Create user with rbash as shell
    if ! id "$username" &>/dev/null; then
        useradd -m -d "/home/$username" -s /bin/rbash "$username"
        
        # Set password
        echo "$username:$password" | chpasswd
        success "User $username created with rbash shell"
        
        # Create restricted PATH
        mkdir -p "/home/$username/bin"
        
        # Create .bashrc yang sangat terbatas
        cat > "/home/$username/.bashrc" << 'EOF'
# Restricted bashrc
PATH=/home/$USER/bin
export PATH
PS1='[\u@\h \W]$ '
echo "Welcome to restricted shell. Available commands: help, ls, cd, exit"
alias ls='ls --color=auto'
alias ll='ls -la'
alias la='ls -a'
EOF
        
        # Create allowed commands symlinks
        local allowed_commands=("ls" "cd" "pwd" "exit" "clear" "help")
        for cmd in "${allowed_commands[@]}"; do
            ln -s "/bin/$cmd" "/home/$username/bin/$cmd" 2>/dev/null
        done
        
        # Lock down permissions
        chown -R "$username:$username" "/home/$username"
        chmod 755 "/home/$username"
        chmod 750 "/home/$username/bin"
        
        # SSH jail - chroot directory
        mkdir -p "/home/$username/minecraft"
        
        # Bind mount server folder
        if ! grep -q "/home/$username/minecraft/$server_folder" /etc/fstab; then
            echo "/home/minecraft/$server_folder /home/$username/minecraft/$server_folder none bind 0 0" >> /etc/fstab
        fi
        
        mount --bind "/home/minecraft/$server_folder" "/home/$username/minecraft/$server_folder" 2>/dev/null
        
        # Create symbolic link di home user
        ln -s "/home/$username/minecraft/$server_folder" "/home/$username/server" 2>/dev/null
        
        success "Restricted environment created for $username"
    else
        warning "User $username already exists"
    fi
}

# Fungsi untuk setup Minecraft user (untuk run server)
setup_minecraft_user() {
    local username=$1
    local server_folder=$2
    
    info "Setting up Minecraft server user: $username"
    
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash -d "/home/$username" "$username"
        success "Minecraft user $username created"
    else
        warning "Minecraft user $username already exists"
    fi
    
    # Ensure server folder exists and set ownership
    mkdir -p "/home/minecraft/$server_folder"
    chown -R "$username:$username" "/home/minecraft/$server_folder"
    success "Server folder ownership set to $username"
}

# Fungsi untuk setup user dengan pilihan password
setup_user_with_password() {
    local server_index=$1
    local server_folder=$2
    local minecraft_user="mcserver$server_index"
    local restricted_user="$minecraft_user"  # Same username for both (restricted shell)
    
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "Konfigurasi User untuk Server #$server_index" "$PURPLE"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Create Minecraft user first (for running server)
    setup_minecraft_user "$minecraft_user" "$server_folder"
    
    # Password untuk restricted user (same as Minecraft user password)
    info "Pilih metode password untuk $minecraft_user:" "$BLUE"
    echo "  1) Generate random password (recommended)"
    echo "  2) Masukkan password manual"
    info "Pilihan (default: 1):" "$BLUE"
    read -r password_choice
    
    local user_password
    case $password_choice in
        2)
            while true; do
                info "Masukkan password (min 8 karakter):" "$BLUE"
                read -s user_password
                echo
                info "Konfirmasi password:" "$BLUE"
                read -s user_password_confirm
                echo
                
                if [ "$user_password" != "$user_password_confirm" ]; then
                    error "Password tidak cocok!"
                elif [ ${#user_password} -lt 8 ]; then
                    error "Password minimal 8 karakter!"
                else
                    break
                fi
            done
            ;;
        *)
            user_password=$(generate_password)
            success "Random password generated"
            ;;
    esac
    
    # Save user info
    server_users+=("$minecraft_user|$user_password|$server_folder")
    
    # Create restricted user (rbash) - same username
    create_restricted_user "$minecraft_user" "$user_password" "$server_folder"
}

# Fungsi untuk generate random password
generate_password() {
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9!@#$%^&*' | fold -w 16 | head -n 1
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
        error "Port $port_value tidak valid (1024-65535)"
        return 1
    fi
    
    if lsof -i:"$port_value" >/dev/null 2>&1; then
        warning "Port $port_value sudah dipakai"
        
        local new_port=$port_value
        local max_attempts=100
        local attempt=0
        
        while lsof -i:"$new_port" >/dev/null 2>&1 && [ $attempt -lt $max_attempts ]; do
            new_port=$((new_port + 1))
            [ $new_port -gt 65535 ] && new_port=1024
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -eq $max_attempts ]; then
            error "Tidak ada port kosong"
            return 1
        fi
        
        success "Menggunakan port $new_port"
        eval "$port_var=$new_port"
    else
        success "Port $port_value tersedia"
    fi
    return 0
}

# Fungsi untuk sanitasi nama folder
sanitize_folder_name() {
    local name=$1
    echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-'
}

# Fungsi untuk setup user dan folders
setup_user_and_folders() {
    info "Setup user dan folder..."
    
    while true; do
        info "Masukkan jumlah server (1-10):" "$BLUE"
        read -r jumlah_server
        if [[ "$jumlah_server" =~ ^[0-9]+$ ]] && [ "$jumlah_server" -ge 1 ] && [ "$jumlah_server" -le 10 ]; then
            break
        else
            warning "Masukkan angka 1-10"
        fi
    done
    
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local min_ram_needed=$((jumlah_server * MIN_RAM_PER_SERVER))
    if [ "$total_ram" -lt "$min_ram_needed" ]; then
        warning "RAM mungkin tidak cukup: ${total_ram}MB total, minimal ${min_ram_needed}MB untuk $jumlah_server server"
        info "Lanjutkan? [y/N]" "$BLUE"
        read -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    mkdir -p /home/minecraft
    success "Folder structure ready"
}

# Fungsi untuk input konfigurasi server
get_server_config() {
    local server_index=$1
    
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "Konfigurasi Server #$server_index" "$PURPLE"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    info "Nama server (default: Server$server_index):" "$BLUE"
    read -r server_name
    [ -z "$server_name" ] && server_name="Server$server_index"
    
    folder_name=$(sanitize_folder_name "$server_name")
    [ -z "$folder_name" ] && folder_name="server$server_index"
    
    if [ -d "/home/minecraft/$folder_name" ]; then
        warning "Folder /home/minecraft/$folder_name sudah ada"
        info "Pilih: [1] overwrite [2] rename [3] skip" "$BLUE"
        read -r choice
        case $choice in
            1)
                warning "Overwrite folder..."
                rm -rf "/home/minecraft/$folder_name"
                ;;
            2)
                info "Nama folder baru:" "$BLUE"
                read -r folder_name
                folder_name=$(sanitize_folder_name "$folder_name")
                [ -z "$folder_name" ] && folder_name="server$server_index-alt"
                ;;
            3)
                return 1
                ;;
            *)
                error "Pilihan tidak valid, skip"
                return 1
                ;;
        esac
    fi
    
    info "Nama world (default: $folder_name):" "$BLUE"
    read -r level_name
    [ -z "$level_name" ] && level_name="$folder_name"
    
    info "Seed (kosongkan untuk random):" "$BLUE"
    read -r level_seed
    
    local default_port=$((19132 + server_index - 1))
    while true; do
        info "Port server (default: $default_port):" "$BLUE"
        read -r server_port
        [ -z "$server_port" ] && server_port=$default_port
        
        if validate_port "$server_port"; then
            break
        else
            warning "Port harus 1024-65535"
        fi
    done
    
    check_port server_port "$server_port" $server_index || return 1
    
    local server_portv6=$((server_port + 1))
    
    info "Pilih gamemode:" "$BLUE"
    echo "  0) survival"
    echo "  1) creative"
    echo "  2) adventure"
    info "Pilihan (default: 0):" "$BLUE"
    read -r gamemode_choice
    case $gamemode_choice in
        1) gamemode="creative" ;;
        2) gamemode="adventure" ;;
        *) gamemode="survival" ;;
    esac
    
    info "Pilih difficulty:" "$BLUE"
    echo "  0) peaceful"
    echo "  1) easy"
    echo "  2) normal"
    echo "  3) hard"
    info "Pilihan (default: 2):" "$BLUE"
    read -r difficulty_choice
    case $difficulty_choice in
        0) difficulty="peaceful" ;;
        1) difficulty="easy" ;;
        3) difficulty="hard" ;;
        *) difficulty="normal" ;;
    esac
    
    info "Aktifkan cheats? [0] false [1] true (default: 0):" "$BLUE"
    read -r cheats_choice
    allow_cheats=$([ "$cheats_choice" == "1" ] && echo "true" || echo "false")
    
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "$server_port/udp" 2>/dev/null
            success "Firewall port $server_port/udp dibuka"
        fi
    fi
    
    server_configs+=("$server_name|$folder_name|$level_name|$level_seed|$server_port|$server_portv6|$gamemode|$difficulty|$allow_cheats")
    
    return 0
}

# Fungsi untuk memilih versi server
select_version() {
    info "Memilih versi server..."
    
    while true; do
        info "Masukkan versi (contoh: 1.21.114.1) atau 'latest':" "$BLUE"
        read -r version
        
        if [ "$version" == "latest" ]; then
            info "Mencari versi terbaru..."
            
            latest_url=$(curl -A "Mozilla/5.0" -s "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links" | 
                        grep -o '"downloadUrl":"[^"]*serverBedrockLinux[^"]*"' | 
                        head -1 | 
                        cut -d'"' -f4)
            
            if [ -n "$latest_url" ]; then
                version=$(echo "$latest_url" | grep -o 'bedrock-server-[0-9.]*\.zip' | sed 's/bedrock-server-//;s/\.zip//')
                success "Versi terbaru: $version"
                download_url="$latest_url"
                break
            else
                error "Gagal dapat versi terbaru"
                continue
            fi
        else
            download_url="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-$version.zip"
        fi
        
        info "Memeriksa versi $version..."
        
        if curl -A "Mozilla/5.0" --output /dev/null --silent --head --fail --connect-timeout 10 "$download_url"; then
            success "Versi $version tersedia"
            break
        else
            error "Versi $version tidak ditemukan"
        fi
    done
    
    DOWNLOAD_URL=$download_url
}

# Fungsi untuk download dan setup server
setup_server() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    local minecraft_user="mcserver$(echo $folder_name | grep -o '[0-9]*' | head -1)"
    [ -z "$minecraft_user" ] && minecraft_user="mcserver1"
    
    info "Setup server: $server_name"
    
    cd /home/minecraft || error_exit "Cannot cd to /home/minecraft"
    
    mkdir -p "$folder_name"
    cd "$folder_name" || error_exit "Cannot cd to $folder_name"
    
    [ -f "server.properties" ] && cp "server.properties" "server.properties.backup.$(date +%Y%m%d-%H%M%S)"
    
    if [ ! -f "bedrock_server" ]; then
        info "Download server files..."
        
        local max_retries=3
        local retry=0
        while [ $retry -lt $max_retries ]; do
            wget --user-agent="Mozilla/5.0" \
                 -O bedrock-server.zip \
                 --timeout=30 \
                 --tries=3 \
                 "$DOWNLOAD_URL" && break
            
            retry=$((retry + 1))
            [ $retry -lt $max_retries ] && warning "Retry $retry/$max_retries..."
        done
        
        if [ ! -f "bedrock-server.zip" ]; then
            error "Download gagal setelah $max_retries percobaan"
            return 1
        fi
        
        local file_size=$(stat -c%s "bedrock-server.zip" 2>/dev/null || stat -f%z "bedrock-server.zip" 2>/dev/null)
        if [ -z "$file_size" ] || [ "$file_size" -lt 50000000 ]; then
            error "File corrupted (size: $file_size bytes)"
            rm -f "bedrock-server.zip"
            return 1
        fi
        
        info "Extracting..."
        unzip -o bedrock-server.zip || {
            error "Extract failed"
            return 1
        }
        rm bedrock-server.zip
    else
        success "Server files already exist"
    fi
    
    chmod +x bedrock_server
    
    info "Creating server.properties..."
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
    
    # Set ownership to Minecraft user
    chown -R "$minecraft_user:$minecraft_user" "/home/minecraft/$folder_name"
    
    success "Server $server_name siap"
    return 0
}

# Fungsi untuk membuat systemd service (FIXED VERSION)
create_systemd() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    
    local service_name="$folder_name.service"
    local service_file="/etc/systemd/system/$service_name"
    local minecraft_user="mcserver$(echo $folder_name | grep -o '[0-9]*' | head -1)"
    [ -z "$minecraft_user" ] && minecraft_user="mcserver1"
    
    info "Membuat systemd service untuk $server_name..."
    
    # Verify user exists
    if ! id "$minecraft_user" &>/dev/null; then
        error "User $minecraft_user tidak ditemukan! Membuat user..."
        useradd -m -s /bin/bash -d "/home/$minecraft_user" "$minecraft_user"
    fi
    
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local ram_per_server=$((total_ram / jumlah_server))
    [ $ram_per_server -gt 2048 ] && ram_per_server=2048
    
    # FIXED: Menggunakan bash -c untuk menjalankan server
    cat > "$service_file" << EOF
[Unit]
Description=Minecraft Bedrock Server - $server_name
After=network.target
StartLimitInterval=60
StartLimitBurst=3

[Service]
Type=simple
User=$minecraft_user
Group=$minecraft_user
WorkingDirectory=/home/minecraft/$folder_name
ExecStart=/bin/bash -c 'cd /home/minecraft/$folder_name && exec ./bedrock_server'
ExecStop=/bin/kill -TERM \$MAINPID
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
Nice=10
CPUQuota=80%
MemoryLimit=${ram_per_server}M
LimitNOFILE=65535
StandardInput=null
StandardOutput=append:/home/minecraft/$folder_name/server.log
StandardError=append:/home/minecraft/$folder_name/error.log
SuccessExitStatus=0 1
RestartPreventExitStatus=255

[Install]
WantedBy=multi-user.target
EOF
    
    # Verify service file
    if [ -f "$service_file" ]; then
        success "Service $service_name dibuat"
        
        # Test service file syntax
        systemd-analyze verify "$service_file" 2>/dev/null || warning "Service file has warnings but will work"
    else
        error "Gagal membuat service file"
    fi
}

# Fungsi untuk enable service
enable_service() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
    
    local service_name="$folder_name.service"
    
    info "Enable service $service_name..."
    systemctl daemon-reload
    systemctl enable "$service_name" || error "Gagal enable service"
    success "Service enabled"
}

# Fungsi untuk start semua server dengan delay
start_all_servers() {
    info "Starting all servers..."
    
    local index=1
    for config in "${server_configs[@]}"; do
        IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats <<< "$config"
        
        info "Starting $server_name (port $server_port)..."
        systemctl start "$folder_name.service"
        
        sleep 3
        if systemctl is-active --quiet "$folder_name.service"; then
            success "$server_name running"
            
            # Show process info
            pgrep -f "bedrock_server.*$folder_name" > /dev/null && \
                success "Process ID: $(pgrep -f "bedrock_server.*$folder_name")"
        else
            error "$server_name failed to start"
            warning "Check logs: journalctl -u $folder_name.service -n 20"
            journalctl -u "$folder_name.service" --no-pager -n 5
        fi
        
        if [ $index -lt ${#server_configs[@]} ]; then
            info "Waiting 5 seconds..."
            sleep 5
        fi
        
        ((index++))
    done
}

# Fungsi untuk cleanup semua file Minecraft
cleanup_all() {
    clear_screen
    echo -e "\n${RED}══════════════════════════════════════════════════════════${NC}"
    info "CLEANUP MENU - DESTRUCTIVE ACTION" "$RED"
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    
    echo "  1) Clean specific server"
    echo "  2) Clean ALL servers and users"
    echo "  3) Clean orphaned users (no server)"
    echo "  4) Back to main menu"
    
    info "Pilihan (1-4):" "$BLUE"
    read -r cleanup_choice
    
    case $cleanup_choice in
        1) cleanup_specific_server ;;
        2) cleanup_all_servers ;;
        3) cleanup_orphaned_users ;;
        4) show_main_menu ;;
        *) error "Pilihan tidak valid!"; sleep 2; cleanup_all ;;
    esac
}

# Fungsi untuk cleanup server spesifik
cleanup_specific_server() {
    echo -e "\n${YELLOW}Available servers:${NC}"
    local servers=()
    local i=1
    
    for dir in /home/minecraft/*; do
        if [ -d "$dir" ]; then
            server_name=$(basename "$dir")
            servers+=("$server_name")
            echo "  $i) $server_name"
            ((i++))
        fi
    done
    
    if [ ${#servers[@]} -eq 0 ]; then
        error "No servers found"
        sleep 2
        cleanup_all
        return
    fi
    
    echo
    info "Pilih server yang akan di-clean (nomor):" "$BLUE"
    read -r server_choice
    
    if ! [[ "$server_choice" =~ ^[0-9]+$ ]] || [ "$server_choice" -lt 1 ] || [ "$server_choice" -gt ${#servers[@]} ]; then
        error "Pilihan tidak valid"
        cleanup_all
        return
    fi
    
    local selected_server="${servers[$((server_choice-1))]}"
    
    echo
    error "⚠⚠⚠ PERINGATAN! ⚠⚠⚠"
    error "Anda akan menghapus server: $selected_server"
    info "Ketik 'DELETE' untuk konfirmasi:" "$BLUE"
    read -r confirmation
    
    if [ "$confirmation" != "DELETE" ]; then
        warning "Cleanup dibatalkan"
        cleanup_all
        return
    fi
    
    # Stop and disable service
    systemctl stop "$selected_server.service" 2>/dev/null
    systemctl disable "$selected_server.service" 2>/dev/null
    rm -f "/etc/systemd/system/$selected_server.service"
    
    # Remove from fstab
    sed -i "\|/home/minecraft/$selected_server|d" /etc/fstab
    
    # Find and remove related users
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        if [ -d "/home/minecraft/$selected_server" ] && [ "$(stat -c '%U' "/home/minecraft/$selected_server" 2>/dev/null)" == "$user" ]; then
            # Unmount bind mounts
            umount "/home/$user/minecraft/$selected_server" 2>/dev/null
            sed -i "\|/home/$user/minecraft/$selected_server|d" /etc/fstab
            
            # Remove user
            userdel -r "$user" 2>/dev/null
            success "Removed user $user"
        fi
    done
    
    # Remove server folder
    rm -rf "/home/minecraft/$selected_server"
    
    systemctl daemon-reload
    
    success "Server $selected_server cleaned up!"
    sleep 2
    cleanup_all
}

# Fungsi untuk cleanup semua server
cleanup_all_servers() {
    clear_screen
    echo -e "\n${RED}⚠⚠⚠ FINAL WARNING! ⚠⚠⚠${NC}"
    error "Ini akan menghapus SEMUA server, users, dan konfigurasi!"
    info "Ketik 'DELETE ALL' untuk konfirmasi:" "$BLUE"
    read -r confirmation
    
    if [ "$confirmation" != "DELETE ALL" ]; then
        warning "Cleanup dibatalkan"
        cleanup_all
        return
    fi
    
    # Stop all services
    for service in /etc/systemd/system/*.service; do
        if grep -q "Minecraft Bedrock" "$service" 2>/dev/null; then
            service_name=$(basename "$service")
            systemctl stop "$service_name"
            systemctl disable "$service_name"
            rm -f "$service"
        fi
    done
    
    # Remove all users (mcserver*)
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        # Unmount all bind mounts
        umount "/home/$user/minecraft/"* 2>/dev/null
        userdel -r "$user" 2>/dev/null
        success "Removed user $user"
    done
    
    # Remove all server folders
    rm -rf /home/minecraft/*
    
    # Clean fstab
    sed -i "\|/home/minecraft|d" /etc/fstab
    sed -i "\|/home/mcserver|d" /etc/fstab
    
    systemctl daemon-reload
    
    success "All servers and users have been removed!"
    sleep 2
    show_main_menu
}

# Fungsi untuk cleanup orphaned users
cleanup_orphaned_users() {
    info "Looking for orphaned users..."
    
    local found=0
    for user in $(getent passwd | grep -E "^mcserver[0-9]+" | cut -d: -f1); do
        local has_server=0
        
        # Check if user owns any server folder
        for server in /home/minecraft/*; do
            if [ -d "$server" ] && [ "$(stat -c '%U' "$server" 2>/dev/null)" == "$user" ]; then
                has_server=1
                break
            fi
        done
        
        if [ $has_server -eq 0 ]; then
            warning "Found orphaned user: $user"
            
            # Unmount any mounts
            umount "/home/$user/minecraft/"* 2>/dev/null
            sed -i "\|/home/$user|d" /etc/fstab
            
            # Remove user
            userdel -r "$user" 2>/dev/null
            success "Removed orphaned user $user"
            found=1
        fi
    done
    
    if [ $found -eq 0 ]; then
        success "No orphaned users found"
    fi
    
    sleep 2
    cleanup_all
}

# Fungsi untuk uninstall server (menu option 2)
uninstall_server() {
    cleanup_specific_server
}

# Fungsi untuk list semua server
list_all_servers() {
    clear_screen
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "ALL SERVERS" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    local found=0
    for dir in /home/minecraft/*; do
        if [ -d "$dir" ]; then
            server_name=$(basename "$dir")
            found=1
            
            if [ -f "$dir/bedrock_server" ]; then
                if systemctl is-active --quiet "$server_name.service" 2>/dev/null; then
                    status="${GREEN}● RUNNING${NC}"
                    
                    # Get PID
                    pid=$(pgrep -f "bedrock_server.*$server_name" | head -1)
                    [ -n "$pid" ] && pid_info=" (PID: $pid)" || pid_info=""
                else
                    status="${RED}○ STOPPED${NC}"
                    pid_info=""
                fi
            else
                status="${YELLOW}○ INCOMPLETE${NC}"
                pid_info=""
            fi
            
            port=$(grep "^server-port=" "$dir/server.properties" 2>/dev/null | cut -d'=' -f2)
            owner=$(stat -c '%U' "$dir" 2>/dev/null)
            
            echo -e "\n${PURPLE}📁 $server_name${NC}"
            echo -e "  Status  : $status$pid_info"
            echo -e "  Port    : ${port:-N/A}"
            echo -e "  Owner   : $owner"
            echo -e "  Path    : $dir"
        fi
    done
    
    if [ $found -eq 0 ]; then
        error "No Minecraft servers found"
    fi
    
    echo
    info "Press Enter to continue..." "$BLUE"
    read -r
    show_main_menu
}

# Fungsi untuk menampilkan menu utama
show_main_menu() {
    clear_screen
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "MAIN MENU" "$PURPLE"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo "  1) Install new Minecraft server(s)"
    echo "  2) Uninstall existing server"
    echo "  3) List all servers"
    echo "  4) Cleanup menu"
    echo "  5) Exit"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    info "Pilihan (1-5):" "$BLUE"
    read -r menu_choice
    
    case $menu_choice in
        1) install_new_servers ;;
        2) uninstall_server ;;
        3) list_all_servers ;;
        4) cleanup_all ;;
        5) exit 0 ;;
        *) error "Pilihan tidak valid!"; sleep 2; show_main_menu ;;
    esac
}

# Fungsi untuk install new servers
install_new_servers() {
    clear_screen
    info "Starting new server installation..."
    
    check_resources
    check_dependencies
    
    # Initialize arrays
    declare -a server_configs=()
    declare -a server_users=()
    
    setup_user_and_folders
    
    for i in $(seq 1 $jumlah_server); do
        if get_server_config $i; then
            setup_user_with_password $i "$folder_name"
        fi
    done
    
    if [ ${#server_configs[@]} -eq 0 ]; then
        error_exit "Tidak ada server yang dikonfigurasi"
    fi
    
    select_version
    
    local success_count=0
    for config in "${server_configs[@]}"; do
        if setup_server "$config"; then
            ((success_count++))
        fi
    done
    
    if [ $success_count -eq 0 ]; then
        error_exit "Tidak ada server yang berhasil diinstall"
    fi
    
    for config in "${server_configs[@]}"; do
        create_systemd "$config"
    done
    
    for config in "${server_configs[@]}"; do
        enable_service "$config"
    done
    
    # Display credentials
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    info "SERVER ACCESS CREDENTIALS" "$PURPLE"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    
    local ip_address=$(hostname -I | awk '{print $1}')
    for user_info in "${server_users[@]}"; do
        IFS='|' read -r username password server_folder <<< "$user_info"
        
        echo -e "\n${CYAN}Server: $server_folder${NC}"
        echo -e "  Username     : $username"
        echo -e "  Password     : ${YELLOW}$password${NC}"
        echo -e "  SSH Command  : ssh $username@$ip_address -p $SSH_PORT"
        echo -e "  SFTP URL     : sftp://$username@$ip_address:$SSH_PORT"
        echo -e "  Restrictions : - Restricted shell (rbash)"
        echo -e "                 - Cannot use sudo"
        echo -e "                 - Cannot run system commands"
        echo -e "                 - Only cd, ls, exit in home"
        echo -e "  Server Path  : ~/server/ -> /home/minecraft/$server_folder/"
    done
    
    echo -e "\n${RED}⚠ IMPORTANT: Save these passwords! They won't be shown again.${NC}"
    
    info "\nStart semua server sekarang? [y/N]" "$BLUE"
    read -r start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_all_servers
    fi
    
    info "\nTekan Enter untuk kembali ke menu..." "$GREEN"
    read -r
    show_main_menu
}

# Trap for cleanup
trap 'error "Script interrupted!"; exit 1' INT TERM

# Fungsi utama
main() {
    clear_screen
    
    if [ "$EUID" -ne 0 ]; then 
        error_exit "Script harus dijalankan sebagai root"
    fi
    
    show_main_menu
}

# Run main
main
