#!/bin/bash

# Minecraft Bedrock Server Auto Installer v4.0 - Production Ready
# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Konfigurasi global
SCRIPT_VERSION="4.0"
MIN_DISK_SPACE=1024  # MB
MIN_RAM_PER_SERVER=512  # MB

# Fungsi untuk menampilkan banner
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Minecraft Bedrock Server Auto Installer v$SCRIPT_VERSION        ║"
    echo "║         (Production Ready - Enterprise Grade)           ║"
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

# Fungsi untuk mengecek system resources
check_resources() {
    log "Memeriksa resources sistem..." "$YELLOW"
    
    # Cek disk space
    local available_disk=$(df -m /home | awk 'NR==2 {print $4}')
    if [ "$available_disk" -lt "$MIN_DISK_SPACE" ]; then
        error_exit "Disk space tidak cukup! Minimal ${MIN_DISK_SPACE}MB, tersedia ${available_disk}MB"
    fi
    log "✓ Disk space: ${available_disk}MB tersedia" "$GREEN"
    
    # Cek RAM total
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    log "✓ Total RAM: ${total_ram}MB" "$GREEN"
    
    # Cek OS
    if [ ! -f /etc/debian_version ]; then
        log "⚠ Script ini dioptimalkan untuk Debian/Ubuntu" "$YELLOW"
    fi
}

# Fungsi untuk mengecek dan install dependencies
check_dependencies() {
    log "Memeriksa dependencies..." "$YELLOW"
    
    local deps=("unzip" "curl" "tmux" "systemctl" "chmod" "lsof" "ufw" "wget" "bc")
    local install_packages=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log "⚠ $dep tidak ditemukan" "$YELLOW"
            if [[ $dep == "systemctl" ]]; then
                error_exit "systemctl tidak ditemukan. Sistem harus menggunakan systemd!"
            elif [[ $dep == "chmod" ]]; then
                error_exit "chmod tidak ditemukan. Sistem tidak kompatibel!"
            elif [[ $dep == "ufw" ]]; then
                log "ℹ ufw tidak ditemukan (opsional untuk firewall)" "$YELLOW"
            else
                install_packages+=($dep)
            fi
        else
            log "✓ $dep tersedia" "$GREEN"
        fi
    done
    
    # Install packages jika perlu
    if [ ${#install_packages[@]} -gt 0 ]; then
        log "Menginstall: ${install_packages[*]}" "$YELLOW"
        apt update && apt install -y ${install_packages[*]} || error_exit "Gagal install dependencies"
        log "✓ Dependencies terinstall" "$GREEN"
    fi
}

# Fungsi untuk setup user dan folders
setup_user_and_folders() {
    log "Setup user dan folder..." "$YELLOW"
    
    # Tanya jumlah server dengan validasi
    while true; do
        log "Masukkan jumlah server (1-10):" "$BLUE"
        read -r jumlah_server
        if [[ "$jumlah_server" =~ ^[0-9]+$ ]] && [ "$jumlah_server" -ge 1 ] && [ "$jumlah_server" -le 10 ]; then
            break
        else
            log "⚠ Masukkan angka 1-10" "$YELLOW"
        fi
    done
    
    # Cek RAM cukup untuk semua server
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local min_ram_needed=$((jumlah_server * MIN_RAM_PER_SERVER))
    if [ "$total_ram" -lt "$min_ram_needed" ]; then
        log "⚠ RAM mungkin tidak cukup: ${total_ram}MB total, minimal ${min_ram_needed}MB untuk $jumlah_server server" "$YELLOW"
        log "Lanjutkan? [y/N]" "$BLUE"
        read -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    # Create main folder
    mkdir -p /home/minecraft
    log "✓ Folder /home/minecraft siap" "$GREEN"
    
    # Create users
    for i in $(seq 1 $jumlah_server); do
        local username="mcserver$i"
        if ! id "$username" &>/dev/null; then
            useradd -m -s /bin/bash -d "/home/$username" "$username" 2>/dev/null
            log "✓ User $username dibuat" "$GREEN"
        else
            log "⚠ User $username sudah ada" "$YELLOW"
        fi
    done
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
        log "❌ Port $port_value tidak valid (1024-65535)" "$RED"
        return 1
    fi
    
    if lsof -i:"$port_value" >/dev/null 2>&1; then
        log "⚠ Port $port_value sudah dipakai" "$YELLOW"
        
        # Cari port kosong
        local new_port=$port_value
        local max_attempts=100
        local attempt=0
        
        while lsof -i:"$new_port" >/dev/null 2>&1 && [ $attempt -lt $max_attempts ]; do
            new_port=$((new_port + 1))
            [ $new_port -gt 65535 ] && new_port=1024
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -eq $max_attempts ]; then
            log "❌ Tidak ada port kosong" "$RED"
            return 1
        fi
        
        log "✓ Menggunakan port $new_port" "$GREEN"
        eval "$port_var=$new_port"
    else
        log "✓ Port $port_value tersedia" "$GREEN"
    fi
    return 0
}

# Fungsi untuk sanitasi nama folder
sanitize_folder_name() {
    local name=$1
    # Lowercase, spasi jadi dash, hapus karakter aneh
    echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-'
}

# Fungsi untuk input konfigurasi server
get_server_config() {
    local server_index=$1
    
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "Konfigurasi Server #$server_index" "$PURPLE"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Nama server
    log "Nama server (default: Server$server_index):" "$BLUE"
    read -r server_name
    [ -z "$server_name" ] && server_name="Server$server_index"
    
    # Sanitize folder name
    folder_name=$(sanitize_folder_name "$server_name")
    [ -z "$folder_name" ] && folder_name="server$server_index"
    
    local username="mcserver$server_index"
    
    # Cek folder existing
    if [ -d "/home/minecraft/$folder_name" ]; then
        log "⚠ Folder /home/minecraft/$folder_name sudah ada" "$YELLOW"
        log "Pilih: [1] overwrite [2] rename [3] skip" "$BLUE"
        read -r choice
        case $choice in
            1)
                log "Overwrite folder..." "$YELLOW"
                rm -rf "/home/minecraft/$folder_name"
                ;;
            2)
                log "Nama folder baru:" "$BLUE"
                read -r folder_name
                folder_name=$(sanitize_folder_name "$folder_name")
                [ -z "$folder_name" ] && folder_name="server$server_index-alt"
                ;;
            3)
                return 1
                ;;
            *)
                log "Pilihan tidak valid, skip" "$RED"
                return 1
                ;;
        esac
    fi
    
    # World name
    log "Nama world (default: $folder_name):" "$BLUE"
    read -r level_name
    [ -z "$level_name" ] && level_name="$folder_name"
    
    # Seed
    log "Seed (kosongkan untuk random):" "$BLUE"
    read -r level_seed
    
    # Port
    local default_port=$((19132 + server_index - 1))
    while true; do
        log "Port server (default: $default_port):" "$BLUE"
        read -r server_port
        [ -z "$server_port" ] && server_port=$default_port
        
        if validate_port "$server_port"; then
            break
        else
            log "⚠ Port harus 1024-65535" "$YELLOW"
        fi
    done
    
    # Check port availability
    check_port server_port "$server_port" $server_index || return 1
    
    local server_portv6=$((server_port + 1))
    
    # Gamemode
    log "Pilih gamemode:" "$BLUE"
    echo "  0) survival"
    echo "  1) creative"
    echo "  2) adventure"
    log "Pilihan (default: 0):" "$BLUE"
    read -r gamemode_choice
    case $gamemode_choice in
        1) gamemode="creative" ;;
        2) gamemode="adventure" ;;
        *) gamemode="survival" ;;
    esac
    
    # Difficulty
    log "Pilih difficulty:" "$BLUE"
    echo "  0) peaceful"
    echo "  1) easy"
    echo "  2) normal"
    echo "  3) hard"
    log "Pilihan (default: 2):" "$BLUE"
    read -r difficulty_choice
    case $difficulty_choice in
        0) difficulty="peaceful" ;;
        1) difficulty="easy" ;;
        3) difficulty="hard" ;;
        *) difficulty="normal" ;;
    esac
    
    # Cheats
    log "Aktifkan cheats? [0] false [1] true (default: 0):" "$BLUE"
    read -r cheats_choice
    allow_cheats=$([ "$cheats_choice" == "1" ] && echo "true" || echo "false")
    
    # Open firewall port (if ufw active)
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "$server_port/udp" 2>/dev/null
            log "✓ Firewall port $server_port/udp dibuka" "$GREEN"
        fi
    fi
    
    # Save config
    server_configs+=("$server_name|$folder_name|$level_name|$level_seed|$server_port|$server_portv6|$gamemode|$difficulty|$allow_cheats|$username")
    
    return 0
}

# Fungsi untuk memilih versi server
select_version() {
    log "Memilih versi server..." "$YELLOW"
    
    while true; do
        log "Masukkan versi (contoh: 1.21.114.1) atau 'latest':" "$BLUE"
        read -r version
        
        if [ "$version" == "latest" ]; then
            log "Mencari versi terbaru..." "$YELLOW"
            
            # Multiple API endpoints untuk redundancy
            latest_url=$(curl -A "Mozilla/5.0" -s "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links" | 
                        grep -o '"downloadUrl":"[^"]*serverBedrockLinux[^"]*"' | 
                        head -1 | 
                        cut -d'"' -f4)
            
            if [ -n "$latest_url" ]; then
                version=$(echo "$latest_url" | grep -o 'bedrock-server-[0-9.]*\.zip' | sed 's/bedrock-server-//;s/\.zip//')
                log "✓ Versi terbaru: $version" "$GREEN"
                download_url="$latest_url"
                break
            else
                log "❌ Gagal dapat versi terbaru" "$RED"
                continue
            fi
        else
            download_url="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-$version.zip"
        fi
        
        log "Memeriksa versi $version..." "$YELLOW"
        
        # Cek dengan multiple user agents
        if curl -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --output /dev/null --silent --head --fail --connect-timeout 10 "$download_url"; then
            log "✓ Versi $version tersedia" "$GREEN"
            break
        else
            log "❌ Versi $version tidak ditemukan" "$RED"
        fi
    done
    
    DOWNLOAD_URL=$download_url
}

# Fungsi untuk download dan setup server
setup_server() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats username <<< "$config"
    
    log "Setup server: $server_name" "$YELLOW"
    
    cd /home/minecraft || error_exit "Cannot cd to /home/minecraft"
    
    # Buat folder server
    mkdir -p "$folder_name"
    cd "$folder_name" || error_exit "Cannot cd to $folder_name"
    
    # Backup config
    [ -f "server.properties" ] && cp "server.properties" "server.properties.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Download jika perlu
    if [ ! -f "bedrock_server" ]; then
        log "Download server files..." "$YELLOW"
        
        # Download dengan retry
        local max_retries=3
        local retry=0
        while [ $retry -lt $max_retries ]; do
            wget --user-agent="Mozilla/5.0" \
                 -O bedrock-server.zip \
                 --timeout=30 \
                 --tries=3 \
                 "$DOWNLOAD_URL" && break
            
            retry=$((retry + 1))
            [ $retry -lt $max_retries ] && log "Retry $retry/$max_retries..." "$YELLOW"
        done
        
        # Validasi download
        if [ ! -f "bedrock-server.zip" ]; then
            log "❌ Download gagal setelah $max_retries percobaan" "$RED"
            return 1
        fi
        
        # Cek ukuran file (minimal 50MB)
        local file_size=$(stat -c%s "bedrock-server.zip" 2>/dev/null || stat -f%z "bedrock-server.zip" 2>/dev/null)
        if [ -z "$file_size" ] || [ "$file_size" -lt 50000000 ]; then
            log "❌ File corrupted (size: $file_size bytes)" "$RED"
            rm -f "bedrock-server.zip"
            return 1
        fi
        
        # Extract
        log "Extracting..." "$YELLOW"
        unzip -o bedrock-server.zip || {
            log "❌ Extract failed" "$RED"
            return 1
        }
        rm bedrock-server.zip
    else
        log "✓ Server files already exist" "$GREEN"
    fi
    
    # Set permission
    chmod +x bedrock_server
    
    # Create server.properties
    log "Creating server.properties..." "$YELLOW"
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
    
    # Set ownership
    chown -R "$username:$username" "/home/minecraft/$folder_name"
    
    log "✓ Server $server_name siap" "$GREEN"
    return 0
}

# Fungsi untuk membuat systemd service
create_systemd() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats username <<< "$config"
    
    log "Membuat systemd service untuk $server_name..." "$YELLOW"
    
    local service_name="$folder_name.service"
    local service_file="/etc/systemd/system/$service_name"
    
    # Hitung RAM limit dinamis
    local total_ram=$(free -m | awk '/Mem:/ {print $2}')
    local ram_per_server=$((total_ram / jumlah_server))
    [ $ram_per_server -gt 2048 ] && ram_per_server=2048
    
    # Create systemd service
    cat > "$service_file" << EOF
[Unit]
Description=Minecraft Bedrock Server - $server_name
After=network.target
StartLimitInterval=60
StartLimitBurst=3

[Service]
Type=simple
User=$username
Group=$username
WorkingDirectory=/home/minecraft/$folder_name
ExecStart=/home/minecraft/$folder_name/bedrock_server
ExecStop=/bin/kill -TERM \$MAINPID
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
Nice=10
CPUQuota=80%
MemoryLimit=${ram_per_server}M
LimitNOFILE=65535
StandardOutput=append:/home/minecraft/$folder_name/server.log
StandardError=append:/home/minecraft/$folder_name/error.log

# Crash logging
SuccessExitStatus=0 1
RestartPreventExitStatus=255

[Install]
WantedBy=multi-user.target
EOF
    
    log "✓ Service $service_name dibuat" "$GREEN"
}

# Fungsi untuk enable service
enable_service() {
    local config=$1
    IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats username <<< "$config"
    
    local service_name="$folder_name.service"
    
    log "Enable service $service_name..." "$YELLOW"
    systemctl daemon-reload
    systemctl enable "$service_name" || log "❌ Gagal enable service" "$RED"
    log "✓ Service enabled" "$GREEN"
}

# Fungsi untuk start semua server dengan delay
start_all_servers() {
    log "Starting all servers..." "$YELLOW"
    
    local index=1
    for config in "${server_configs[@]}"; do
        IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats username <<< "$config"
        
        log "Starting $server_name (port $server_port)..." "$YELLOW"
        systemctl start "$folder_name.service"
        
        # Cek status
        sleep 2
        if systemctl is-active --quiet "$folder_name.service"; then
            log "✓ $server_name running" "$GREEN"
        else
            log "❌ $server_name failed to start" "$RED"
            journalctl -u "$folder_name.service" --no-pager -n 5
        fi
        
        # Delay antar server
        if [ $index -lt ${#server_configs[@]} ]; then
            log "Waiting 5 seconds..." "$YELLOW"
            sleep 5
        fi
        
        ((index++))
    done
}

# Fungsi untuk menampilkan summary
show_summary() {
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    log "INSTALASI SELESAI!" "$GREEN"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    
    local index=1
    for config in "${server_configs[@]}"; do
        IFS='|' read -r server_name folder_name level_name level_seed server_port server_portv6 gamemode difficulty allow_cheats username <<< "$config"
        
        echo -e "\n${PURPLE}━━━━━━ Server #$index: $server_name ━━━━━━${NC}"
        echo -e "  📁 Folder    : /home/minecraft/$folder_name"
        echo -e "  👤 User      : $username"
        echo -e "  🌐 Port      : $server_port (UDP)"
        echo -e "  🎮 Gamemode  : $gamemode"
        echo -e "  📊 Difficulty: $difficulty"
        echo -e "  ⚡ Cheats    : $allow_cheats"
        echo -e "  🗺️ World     : $level_name"
        echo -e "  🎲 Seed      : ${level_seed:-random}"
        echo -e "  🔧 Service   : $folder_name.service"
        
        # Status
        if systemctl is-active --quiet "$folder_name.service"; then
            echo -e "  ✅ Status    : ${GREEN}RUNNING${NC}"
        else
            echo -e "  ❌ Status    : ${RED}STOPPED${NC}"
        fi
        
        ((index++))
    done
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════${NC}"
    log "Commands:" "$CYAN"
    echo -e "  systemctl start <service>    # Start server"
    echo -e "  systemctl stop <service>     # Stop server"
    echo -e "  systemctl status <service>   # Cek status"
    echo -e "  journalctl -u <service> -f   # Live logs"
    echo -e "  tail -f /home/minecraft/*/server.log  # All logs"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
}

# Fungsi untuk cleanup on error
cleanup() {
    log "Cleaning up..." "$YELLOW"
    rm -f /tmp/bedrock-*.tmp 2>/dev/null
}

# Trap for cleanup
trap cleanup EXIT

# Fungsi utama
main() {
    show_banner
    
    # Cek root
    if [ "$EUID" -ne 0 ]; then 
        error_exit "Script harus dijalankan sebagai root untuk setup systemd"
    fi
    
    # Inisialisasi
    check_resources
    check_dependencies
    setup_user_and_folders
    
    # Array config
    declare -a server_configs=()
    
    # Loop config server
    for i in $(seq 1 $jumlah_server); do
        if ! get_server_config $i; then
            log "⚠ Server #$i skipped" "$YELLOW"
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
    
    # Tanya start sekarang
    log "\nStart semua server sekarang? [y/N]" "$BLUE"
    read -r start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        start_all_servers
    fi
    
    # Tampilkan summary
    show_summary
    
    log "\nTekan Enter untuk keluar..." "$GREEN"
    read -r
}

# Run main
main
