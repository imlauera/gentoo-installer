#!/bin/bash
# gentoo-install.sh — Instalador de Gentoo OpenRC con binarios
# Basado en https://imlauera.github.io/post/gentoo_installation/
#            https://imlauera.github.io/gentoo_openrc/
# Ejecutar desde Arch Linux como root

set -e

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ask()     { echo -e "${CYAN}[?]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"
            echo -e "${BLUE}  $*${NC}"
            echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ─── Trap: limpiar si falla ─────────────────────────────────────────────────
DEBUGINFOD_BACKUP=0
cleanup() {
    local CODE=$?
    [[ $CODE -eq 0 ]] && return 0
    warn "Fallo (codigo $CODE). Desmontando..."
    [[ "$DEBUGINFOD_BACKUP" == "1" ]] && \
        mv /etc/profile.d/debuginfod.sh.bak /etc/profile.d/debuginfod.sh 2>/dev/null || true
    umount -R /mnt/gentoo/proc 2>/dev/null || true
    umount -R /mnt/gentoo/sys  2>/dev/null || true
    umount -R /mnt/gentoo/dev  2>/dev/null || true
    umount    /mnt/gentoo/run  2>/dev/null || true
    umount    /mnt/gentoo/boot 2>/dev/null || true
    umount    /mnt/gentoo      2>/dev/null || true
    warn "Desmontado. Swap intacta."
}
trap cleanup EXIT

# ─── Verificaciones ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Ejecuta como root: sudo bash $0"
command -v arch-chroot &>/dev/null || error "Instala arch-install-scripts primero."
command -v genfstab   &>/dev/null || error "Instala arch-install-scripts primero."

# ─── Parametros CLI ─────────────────────────────────────────────────────────
# Uso: bash gentoo-install.sh --efi /dev/sda2 --swap /dev/sda3 --root /dev/sda4
#        --hostname gentoo --user miusuario --pass mipass --cores 2
#        --wifi-iface wlp1s0 --wifi-ssid MiRed --wifi-pass wifipass
PART_EFI=""; PART_SWAP=""; PART_ROOT=""
HOSTNAME=""; USERNAME=""; USER_PASS=""; USER_PASS2=""
WIFI_IFACE=""; WIFI_SSID=""; WIFI_PASS=""
CPU_CORES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --efi)        PART_EFI="$2";   shift 2 ;;
        --swap)       PART_SWAP="$2";  shift 2 ;;
        --root)       PART_ROOT="$2";  shift 2 ;;
        --hostname)   HOSTNAME="$2";   shift 2 ;;
        --user)       USERNAME="$2";   shift 2 ;;
        --pass)       USER_PASS="$2";  USER_PASS2="$2"; shift 2 ;;
        --cores)      CPU_CORES="$2";  shift 2 ;;
        --wifi-iface) WIFI_IFACE="$2"; shift 2 ;;
        --wifi-ssid)  WIFI_SSID="$2";  shift 2 ;;
        --wifi-pass)  WIFI_PASS="$2";  shift 2 ;;
        --help|-h)
            echo "Uso: bash $0 [opciones]"
            echo "  --efi        /dev/sdXN  Particion EFI (FAT32)"
            echo "  --swap       /dev/sdXN  Particion swap (no se formatea)"
            echo "  --root       /dev/sdXN  Particion root (SE FORMATEA ext4)"
            echo "  --hostname   nombre     Hostname"
            echo "  --user       nombre     Usuario a crear"
            echo "  --pass       pass       Contrasena para root y usuario"
            echo "  --cores      N          Nucleos de CPU"
            echo "  --wifi-iface wlp1s0     Interfaz WiFi"
            echo "  --wifi-ssid  MiRed      SSID"
            echo "  --wifi-pass  pass       Contrasena WiFi"
            echo ""
            echo "Sin parametros: modo interactivo."
            trap - EXIT; exit 0 ;;
        *) warn "Parametro desconocido: $1"; shift ;;
    esac
done

# ─── Interactivo (solo lo que falta) ────────────────────────────────────────
section "Discos disponibles"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
echo ""
section "Configuracion"

[[ -z "$PART_EFI" ]]   && { ask "Particion EFI  (ej: /dev/sda2):";                   read -r PART_EFI; }
[[ -z "$PART_SWAP" ]]  && { ask "Particion swap (ej: /dev/sda3) - sin formatear:";   read -r PART_SWAP; }
[[ -z "$PART_ROOT" ]]  && { ask "Particion root (ej: /dev/sda4) - SE FORMATEARA:";   read -r PART_ROOT; }
[[ -z "$HOSTNAME" ]]   && { ask "Hostname (ej: gentoo):";                             read -r HOSTNAME; }
[[ -z "$USERNAME" ]]   && { ask "Nombre de usuario:";                                 read -r USERNAME; }
[[ -z "$CPU_CORES" ]]  && { ask "Nucleos de CPU (ej: 2):";                            read -r CPU_CORES; }

if [[ -z "$WIFI_IFACE" ]]; then
    ask "Interfaz WiFi (ej: wlp1s0 - Enter para omitir):"
    read -r WIFI_IFACE
fi
if [[ -n "$WIFI_IFACE" && -z "$WIFI_SSID" ]]; then
    ask "SSID de tu WiFi:"; read -r WIFI_SSID
fi
if [[ -n "$WIFI_SSID" && -z "$WIFI_PASS" ]]; then
    ask "Contrasena WiFi:"; read -rs WIFI_PASS; echo ""
fi
if [[ -z "$USER_PASS" ]]; then
    ask "Contrasena para root y para $USERNAME:"; read -rs USER_PASS;  echo ""
    ask "Repeti la contrasena:";                  read -rs USER_PASS2; echo ""
    [[ "$USER_PASS" == "$USER_PASS2" ]] || error "Las contrasenas no coinciden."
fi

MAKEJOBS=$((CPU_CORES + 1))

section "Resumen"
echo "  EFI:      $PART_EFI"
echo "  Swap:     $PART_SWAP  (sin formatear)"
echo "  Root:     $PART_ROOT  <- SE FORMATEARA ext4"
echo "  Hostname: $HOSTNAME"
echo "  Usuario:  $USERNAME"
echo "  WiFi:     ${WIFI_IFACE:-no configurado}"
echo "  SSID:     ${WIFI_SSID:-no configurado}"
echo "  MAKEOPTS: -j${MAKEJOBS} -l${CPU_CORES}"
echo ""
warn "La particion $PART_ROOT se formateara! Continuar? (s/N)"
read -r CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; trap - EXIT; exit 0; }

# ─── Particiones ────────────────────────────────────────────────────────────
section "Preparando particiones"
info "Formateando $PART_ROOT como ext4..."
mkfs.ext4 -F -F "$PART_ROOT"

info "Activando swap $PART_SWAP..."
swapon "$PART_SWAP" 2>/dev/null || warn "Swap ya estaba activa, continuando."

info "Montando root en /mnt/gentoo..."
mkdir -p /mnt/gentoo
mount "$PART_ROOT" /mnt/gentoo

info "Montando EFI en /mnt/gentoo/boot..."
mkdir -p /mnt/gentoo/boot
mount "$PART_EFI" /mnt/gentoo/boot

# ─── Stage3 ─────────────────────────────────────────────────────────────────
section "Descargando stage3 desktop-openrc"

MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds"
SUBDIR="current-stage3-amd64-desktop-openrc"
LATEST_TXT="$MIRROR/$SUBDIR/latest-stage3-amd64-desktop-openrc.txt"

info "Buscando ultima version..."
# El archivo viene firmado con PGP; la linea del tarball empieza con "stage3-"
STAGE3_NAME=$(curl -s "$LATEST_TXT" | grep -E '^stage3-.*\.tar\.xz' | head -1 | awk '{print $1}')
[[ -z "$STAGE3_NAME" ]] && error "No se pudo obtener el nombre del stage3. Verificar conexion."

STAGE3_URL="$MIRROR/$SUBDIR/$STAGE3_NAME"
info "Descargando $STAGE3_NAME desde $STAGE3_URL ..."
cd /mnt/gentoo
wget -c "$STAGE3_URL" -O "$STAGE3_NAME"

info "Extrayendo stage3..."
tar xpf "$STAGE3_NAME" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
rm -f "$STAGE3_NAME"

# ─── make.conf ──────────────────────────────────────────────────────────────
section "Configurando make.conf"
cat > /mnt/gentoo/etc/portage/make.conf << MAKEEOF
# Generado por gentoo-install.sh
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"
LC_MESSAGES=C.utf8
MAKEOPTS="-j${MAKEJOBS} -l${CPU_CORES}"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature"
EMERGE_DEFAULT_OPTS="\${EMERGE_DEFAULT_OPTS} --getbinpkg --binpkg-respect-use=n --autounmask-backtrack=y"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="amd64"
USE="elogind -systemd -dist-kernel -gnome -kde -qt5 X alsa wifi"
MAKEEOF
info "make.conf escrito."

# ─── DNS ────────────────────────────────────────────────────────────────────
info "Configurando DNS Quad9 (sin censura)..."
cat > /mnt/gentoo/etc/resolv.conf << 'DNSEOF'
nameserver 9.9.9.11
nameserver 149.112.112.11
DNSEOF

# ─── Filesystems virtuales ──────────────────────────────────────────────────
section "Montando filesystems virtuales"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys && mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev && mount --make-rslave /mnt/gentoo/dev
mount --bind  /run /mnt/gentoo/run && mount --make-slave  /mnt/gentoo/run
if test -L /dev/shm; then rm /dev/shm && mkdir /dev/shm; fi
mount --types tmpfs --options nosuid,nodev,noexec shm /dev/shm
chmod 1777 /dev/shm

# ─── Fix debuginfod.sh (causa "unbound variable" en arch-chroot) ────────────
if [[ -f /etc/profile.d/debuginfod.sh ]]; then
    warn "Desactivando temporalmente debuginfod.sh..."
    mv /etc/profile.d/debuginfod.sh /etc/profile.d/debuginfod.sh.bak
    DEBUGINFOD_BACKUP=1
fi

# ─── fstab ──────────────────────────────────────────────────────────────────
section "Generando fstab"
genfstab -U /mnt/gentoo > /mnt/gentoo/etc/fstab
cat /mnt/gentoo/etc/fstab

# ─── Script de chroot ────────────────────────────────────────────────────────
# Usamos printf para evitar problemas con heredocs anidados y expansion de variables
section "Generando script interno de chroot"

SETUP=/mnt/gentoo/root/setup.sh


# Variables a expandir AHORA (desde el host)
H="$HOSTNAME"
U="$USERNAME"
P="$USER_PASS"
WI="$WIFI_IFACE"
WS="$WIFI_SSID"
WP="$WIFI_PASS"
MJ="$MAKEJOBS"
MC="$CPU_CORES"

python3 - "$SETUP" "$H" "$U" "$P" "$WI" "$WS" "$WP" "$MJ" "$MC" << 'PYEOF'
import sys, os

path, H, U, P, WI, WS, WP, MJ, MC = sys.argv[1:]

script = f"""#!/bin/bash
set -e
RED='\\033[0;31m'; GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; NC='\\033[0m'
info() {{ echo -e "${{GREEN}}[+]${{NC}} $*"; }}
warn() {{ echo -e "${{YELLOW}}[!]${{NC}} $*"; }}
source /etc/profile 2>/dev/null || true

info "=== Sincronizando portage (primero) ==="
emerge-webrsync

info "=== Timezone ==="
ln -sf /usr/share/zoneinfo/America/Buenos_Aires /etc/localtime
hwclock --systohc
echo "America/Buenos_Aires" > /etc/timezone
emerge --config sys-libs/timezone-data

info "=== Locale ==="
printf 'en_US ISO-8859-1\\nen_US.UTF-8 UTF-8\\n' > /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile 2>/dev/null || true

info "=== Teclado (OpenRC) ==="
# OpenRC usa /etc/conf.d/keymaps y /etc/conf.d/consolefont (NO vconsole.conf, eso es systemd)
echo 'keymap="es"'                    > /etc/conf.d/keymaps
echo 'consolefont="latarcyrheb-sun32"' > /etc/conf.d/consolefont
rc-update add keymaps boot
rc-update add consolefont boot

info "=== Binhost ==="
# El stage3 desktop-openrc ya viene con el binhost configurado por defecto
# Solo nos aseguramos de bajar las firmas
getuto 2>/dev/null || warn "getuto fallo, continuando..."

info "=== CPU flags ==="
emerge --getbinpkg --oneshot app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

info "=== @world salteado — correr despues del primer boot: emerge -uDN @world ==="
# emerge --getbinpkg --binpkg-respect-use=n -uDN @world

info "=== linux-firmware ==="
# No esta en el binhost pero no compila nada, solo instala archivos de firmware
emerge sys-kernel/linux-firmware

info "=== sof-firmware / intel-microcode ==="
emerge -G --binpkg-respect-use=n sys-firmware/sof-firmware sys-firmware/intel-microcode 2>/dev/null || warn "No disponibles como binarios, omitiendo."

info "=== gentoo-kernel-bin ==="
# Dracut detecta el chroot y necesita un cmdline explicito para generar el initramfs
# https://wiki.gentoo.org/wiki/Installkernel#Install_chroot_check
mkdir -p /etc/cmdline.d
echo "root=UUID=$(findmnt -no UUID /) ro quiet" > /etc/cmdline.d/root.conf
emerge sys-kernel/gentoo-kernel-bin

info "=== GRUB + efibootmgr ==="
emerge -g sys-boot/grub sys-boot/efibootmgr || emerge --binpkg-respect-use=n sys-boot/grub sys-boot/efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Guardar info del kernel para el aviso final
KERNEL_VER=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | xargs basename | sed 's/vmlinuz-//')
ROOT_UUID=$(findmnt -no UUID /)
EFI_PART=$(findmnt -no SOURCE /boot)
EFI_GPT=$(lsblk -no NAME,TYPE "$EFI_PART" 2>/dev/null | head -1 | awk "{print \$1}" || echo "sdaX")

info "=== Hostname ==="
echo "{H}" > /etc/hostname
printf '127.0.0.1   {H}.localdomain {H} localhost\\n::1         {H}.localdomain {H} localhost\\n' > /etc/hosts

info "=== Servicios base ==="
emerge -g app-admin/sysklogd sys-process/cronie net-misc/chrony || \\
    emerge --binpkg-respect-use=n app-admin/sysklogd sys-process/cronie net-misc/chrony
rc-update add sysklogd default
rc-update add cronie default
rc-update add chronyd default

info "=== sudo ==="
emerge -g app-admin/sudo || emerge --binpkg-respect-use=n app-admin/sudo
echo "%wheel ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers

info "=== wpa_supplicant + dhcpcd ==="
echo "net-wireless/wpa_supplicant tkip" > /etc/portage/package.use/wpa_supplicant
emerge -g net-wireless/wpa_supplicant net-misc/dhcpcd net-wireless/wireless-tools || \\
    emerge --binpkg-respect-use=n net-wireless/wpa_supplicant net-misc/dhcpcd net-wireless/wireless-tools

mkdir -p /etc/wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf << 'WEOF'
ctrl_interface=/run/wpa_supplicant
update_config=1
country=AR
WEOF
"""

if WS and WP:
    script += f"""
info "=== Agregando red WiFi {WS} ==="
wpa_passphrase "{WS}" "{WP}" >> /etc/wpa_supplicant/wpa_supplicant.conf
"""

if WI:
    script += f"""
info "=== Configurando WiFi OpenRC ({WI}) ==="
cat > /etc/conf.d/net << 'NEOF'
modules="wpa_supplicant"
wpa_supplicant_{WI}="-Dnl80211 -c/etc/wpa_supplicant/wpa_supplicant.conf"
config_{WI}="dhcp"
NEOF
ln -sf /etc/init.d/net.lo /etc/init.d/net.{WI} 2>/dev/null || true
rc-update add net.{WI} default

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/rtl8723be.conf << 'MEOF'
# Fix antena WiFi rtl8723be
options rtl8723be ant_sel=1
MEOF
echo 'options cfg80211 ieee80211_regdom=AR' > /etc/modprobe.d/wireless.conf
"""

script += f"""
info "=== Usuario {U} ==="
useradd -m -G users,video,audio,wheel -s /bin/bash "{U}"
echo "{U}:{P}" | chpasswd
echo "root:{P}" | chpasswd

info ""
info "=== INSTALACION COMPLETADA ==="
info "Al bootear: logueate como {U}"
info ""
info "WiFi manual si no arranca:"
info "  ip link set {WI or 'wlp1s0'} up"
info "  wpa_supplicant -B -i {WI or 'wlp1s0'} -c /etc/wpa_supplicant/wpa_supplicant.conf"
info "  dhcpcd {WI or 'wlp1s0'}"
info ""
KERNEL_VER=$(ls /boot/vmlinuz-* 2>/dev/null | grep -v rescue | head -1 | sed 's|/boot/vmlinuz-||')
ROOT_UUID=$(findmnt -no UUID /)
warn "=== DUAL BOOT: ENTRADA MANUAL EN GRUB DE ARCH ==="
warn "os-prober no genera bien la entrada cuando cada distro tiene su propia EFI."
warn "Agrega esto en /etc/grub.d/40_custom de tu Arch y corre grub-mkconfig:"
warn ""
warn "menuentry \'Gentoo Linux\' --class gentoo --class gnu-linux --class gnu --class os {{"
warn "    insmod part_gpt"
warn "    insmod ext2"
warn "    set root=\'hd0,gpt4\'"
warn "    search --no-floppy --fs-uuid --set=root $ROOT_UUID"
warn "    linux (hd0,gpt2)/vmlinuz-$KERNEL_VER root=UUID=$ROOT_UUID rw"
warn "    initrd (hd0,gpt2)/initramfs-$KERNEL_VER.img"
warn "}}"
warn ""
warn "Ajusta hd0,gpt2 y hd0,gpt4 segun tu layout de disco."
"""

with open(path, 'w') as f:
    f.write(script)
os.chmod(path, 0o755)
print(f"Setup script escrito en {path}")
PYEOF

info "Script de chroot generado."

# ─── Ejecutar chroot ─────────────────────────────────────────────────────────
section "Ejecutando configuracion dentro del chroot"
info "Para monitorear en otra terminal: tail -f /mnt/gentoo/var/log/emerge.log"
echo ""
arch-chroot /mnt/gentoo /bin/bash /root/setup.sh

# ─── Restaurar debuginfod.sh ─────────────────────────────────────────────────
if [[ "$DEBUGINFOD_BACKUP" == "1" ]]; then
    mv /etc/profile.d/debuginfod.sh.bak /etc/profile.d/debuginfod.sh
    info "debuginfod.sh restaurado."
fi

# ─── Limpiar y desmontar ─────────────────────────────────────────────────────
rm -f /mnt/gentoo/root/setup.sh
section "Desmontando particiones"
umount -R /mnt/gentoo/proc 2>/dev/null || true
umount -R /mnt/gentoo/sys  2>/dev/null || true
umount -R /mnt/gentoo/dev  2>/dev/null || true
umount    /mnt/gentoo/run  2>/dev/null || true
umount    /mnt/gentoo/boot 2>/dev/null || true
umount    /mnt/gentoo      2>/dev/null || true

# Quitar el trap para que no dispare cleanup en exit 0
trap - EXIT

section "Listo! Podes reiniciar con: reboot"
info "Guias: https://imlauera.github.io/post/gentoo_installation/"
info "       https://imlauera.github.io/gentoo_openrc/"
