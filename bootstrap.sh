#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - Configuration initiale d'un serveur Debian / Ubuntu
# Dépôt : https://github.com/bapt-git/Ubuntu-serv-setup
#
# Usage (terminal interactif obligatoire) :
#   curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh -o bootstrap.sh
#   sudo bash bootstrap.sh
#
# Déjà en root (sudo -i) :
#   curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | bash
#
# NE PAS utiliser "curl ... | sudo bash" : sur Ubuntu 26.04 (sudo-rs) le script
# est suspendu dès qu'il pose une question. Le script refuse ce mode.
#
# Détecte aussi les disques supplémentaires non montés (disque data des VM) et
# propose de les monter, avec montage automatique au démarrage.
#
# Toutes les questions sont posées au début, un récapitulatif est affiché,
# puis la configuration s'exécute sans interruption et se termine par une
# vérification point par point.
# =============================================================================
set -Eeuo pipefail

# ----------------------------- Constantes ------------------------------------
readonly TIMEZONE="Europe/Paris"
readonly LOG_FILE="/var/log/bootstrap.log"
readonly SSHD_MAIN="/etc/ssh/sshd_config"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/00-bootstrap.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/10-bootstrap.local"
readonly PACKAGES=(
  sudo openssh-server ufw fail2ban python3-systemd unattended-upgrades
  htop curl wget git nano ncdu tmux unzip rsync ca-certificates gnupg
)
readonly KEY_TYPES='(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)'

# ----------------------------- Réponses --------------------------------------
ADMIN_USER=""
USER_EXISTS=0
SSH_PORT="22"
NEW_HOSTNAME=""
PASSWORDLESS_SUDO=0
HARDEN_SSH=0
ADMIN_PASS=""
SSH_KEYS=()
EXISTING_KEYS=0
FAILS=0
EXEC_PHASE=0
STEP_N=0
STEP_TOTAL=0
# Disques à monter (un index par montage)
MOUNT_DEV=()      # disque (si formatage) ou partition existante
MOUNT_POINT=()    # point de montage
MOUNT_FORMAT=()   # 1 = disque vide à initialiser (GPT + ext4)
MOUNT_UUID=()     # rempli à l'exécution

# ----------------------------- Affichage -------------------------------------
C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
info()    { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()     { printf '%s[ERR ]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
section() {
  if (( EXEC_PHASE )); then
    STEP_N=$((STEP_N + 1))
    printf '\n%s== [%d/%d %s] %s ==%s\n' "$C_BOLD" "$STEP_N" "$STEP_TOTAL" "$(date +%T)" "$*" "$C_RESET"
  else
    printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"
  fi
}
trap 'die "Erreur ligne $LINENO (commande : $BASH_COMMAND)"' ERR

# ----------------------------- Saisie (toujours via /dev/tty) ----------------
# /dev/tty permet de poser les questions même avec "curl | bash".
tty_print() { printf '%s\n' "$*" >/dev/tty; }

ask() { # ask "Question" ["défaut"] -> réponse sur stdout
  local prompt="$1" default="${2:-}" reply=""
  if [[ -n "$default" ]]; then
    printf '%s [%s] : ' "$prompt" "$default" >/dev/tty
  else
    printf '%s : ' "$prompt" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

ask_yn() { # ask_yn "Question" "o|n" -> code retour 0 si oui
  local r
  while true; do
    r="$(ask "$1 (o/n)" "$2")"
    case "${r,,}" in
      o|oui|y|yes) return 0 ;;
      n|non|no)    return 1 ;;
      *) tty_print "  Répondre o ou n." ;;
    esac
  done
}

ask_secret() { # saisie masquée
  local p=""
  printf '%s : ' "$1" >/dev/tty
  IFS= read -rs p </dev/tty || p=""
  printf '\n' >/dev/tty
  printf '%s' "$p"
}

# ----------------------------- Clés SSH --------------------------------------
is_valid_key() {
  [[ "$1" =~ ^${KEY_TYPES}\ [A-Za-z0-9+/]+={0,3}(\ .*)?$ ]] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -l -f /dev/stdin <<<"$1" >/dev/null 2>&1
  fi
}

# Extrait les clés d'un authorized_keys en retirant les options en tête de ligne
# (ex. clés root des images cloud préfixées par command="echo 'Please login as...'").
extract_keys() {
  [[ -r "$1" ]] || return 0
  grep -oE "${KEY_TYPES} [A-Za-z0-9+/]+={0,3}( [^\"]*)?\$" "$1" 2>/dev/null || true
}

key_label() { # type + commentaire, pour affichage
  awk '{ c=""; for (i=3;i<=NF;i++) c=c (i>3?" ":"") $i; print $1 (c!="" ? "  (" c ")" : "") }' <<<"$1"
}

add_key() { # ajoute une clé si son contenu n'est pas déjà présent
  local k="$1" body e
  body="$(awk '{print $2}' <<<"$k")"
  for e in "${SSH_KEYS[@]}"; do
    if [[ "$(awk '{print $2}' <<<"$e")" == "$body" ]]; then return 0; fi
  done
  SSH_KEYS+=("$k")
}

# ----------------------------- Disques ---------------------------------------
readonly MIN_DISK_BYTES=$((1024 * 1024 * 1024))   # ignore < 1 Gio (lecteurs cloud-init, etc.)
readonly MOUNTABLE_FS='^(ext2|ext3|ext4|xfs|btrfs)$'

list_disks() { # disques physiques/virtuels (hors zram, loop, lecteurs optiques...)
  lsblk -dnrpo NAME,TYPE | awk '$2 == "disk" && $1 !~ /^\/dev\/(zram|loop|ram|sr|fd)/ { print $1 }'
}
human_size() { lsblk -dno SIZE "$1" | tr -d ' '; }

# Disque utilisé : quelque chose de monté (ou swap actif) dessus,
# ou membre LVM / RAID / LUKS / ZFS -> à traiter à la main
disk_is_busy() {
  local d="$1"
  if lsblk -nro MOUNTPOINT "$d" | grep -q .; then return 0; fi
  if lsblk -nro TYPE "$d" | grep -qvE '^(disk|part)$'; then return 0; fi
  if lsblk -nro FSTYPE "$d" | grep -qE 'LVM2_member|linux_raid_member|crypto_LUKS|swap|zfs_member'; then return 0; fi
  return 1
}

# Disque vierge : ni partition, ni table de partitions, ni système de fichiers
disk_is_empty() {
  local d="$1"
  [[ "$(lsblk -nrpo NAME "$d" | wc -l)" -eq 1 ]] || return 1
  [[ -z "$(blkid -p -o value -s TYPE "$d" 2>/dev/null || true)" ]] || return 1
  [[ -z "$(blkid -p -o value -s PTTYPE "$d" 2>/dev/null || true)" ]]
}

# Partitions (ou disque entier) portant un système de fichiers montable
mountable_devs() {
  local d="$1" dev fs
  while IFS= read -r dev; do
    fs="$(lsblk -ndo FSTYPE "$dev" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$fs" =~ $MOUNTABLE_FS ]]; then printf '%s\n' "$dev"; fi
  done < <(lsblk -nrpo NAME "$d")
}

dev_desc() { # "ext4, 100G, label data"
  local dev="$1" fs size label
  fs="$(lsblk -ndo FSTYPE "$dev" | tr -d ' ')"
  size="$(lsblk -ndo SIZE "$dev" | tr -d ' ')"
  label="$(lsblk -ndo LABEL "$dev" 2>/dev/null || true)"
  printf '%s, %s%s' "$fs" "$size" "${label:+, label $label}"
}

# Normalise et valide un point de montage. Affiche le chemin retenu, ou rien si refusé.
check_mountpoint() {
  local mp="$1" planned
  [[ "$mp" == /* ]] || mp="/$mp"
  mp="${mp%/}"
  if [[ ! "$mp" =~ ^(/[A-Za-z0-9._-]+)+$ ]]; then
    tty_print "  Chemin invalide (lettres, chiffres, . _ - et /)."; return 1
  fi
  case "$mp" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/snap|/srv|/sys|/tmp|/usr|/var \
    |/bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/tmp/*|/usr/*)
      tty_print "  $mp est un répertoire système, choisis un autre chemin (ex. /data, /srv/data, /var/lib/docker)."; return 1 ;;
  esac
  for planned in "${MOUNT_POINT[@]}"; do
    if [[ "$planned" == "$mp" ]]; then tty_print "  $mp est déjà choisi pour un autre disque."; return 1; fi
  done
  if findmnt -n "$mp" >/dev/null 2>&1 || findmnt -sn "$mp" >/dev/null 2>&1; then
    tty_print "  $mp est déjà monté ou déjà déclaré dans /etc/fstab."; return 1
  fi
  if [[ -e "$mp" ]]; then
    if [[ ! -d "$mp" ]]; then tty_print "  $mp existe et n'est pas un dossier."; return 1; fi
    if [[ -n "$(ls -A "$mp" 2>/dev/null || true)" ]]; then
      tty_print "  $mp n'est pas vide : son contenu serait masqué par le montage."; return 1
    fi
  fi
  printf '%s' "$mp"
}

next_default_mp() { # /data, puis /data2, /data3...
  local n=1 mp="/data" planned taken
  while true; do
    taken=0
    for planned in "${MOUNT_POINT[@]}"; do [[ "$planned" == "$mp" ]] && taken=1; done
    if (( ! taken )) && ! findmnt -sn "$mp" >/dev/null 2>&1 && [[ ! -e "$mp" || -z "$(ls -A "$mp" 2>/dev/null || true)" ]]; then
      printf '%s' "$mp"; return
    fi
    n=$((n + 1)); mp="/data$n"
  done
}

ask_mountpoint() { # ask_mountpoint "Question" -> chemin validé
  local reply mp
  while true; do
    reply="$(ask "$1" "$(next_default_mp)")"
    if mp="$(check_mountpoint "$reply")" && [[ -n "$mp" ]]; then printf '%s' "$mp"; return; fi
  done
}

plan_mount() { MOUNT_DEV+=("$1"); MOUNT_POINT+=("$2"); MOUNT_FORMAT+=("$3"); }

ask_disks() {
  local d size devs=() dev mp found=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if (( $(lsblk -dnbo SIZE "$d") < MIN_DISK_BYTES )); then continue; fi
    if [[ "$(lsblk -dno RO "$d" | tr -d ' ')" == "1" ]]; then continue; fi
    if disk_is_busy "$d"; then continue; fi
    found=1
    size="$(human_size "$d")"

    if disk_is_empty "$d"; then
      tty_print "Disque non utilisé : $d ($size, vierge)"
      if ask_yn "  Le formater (GPT + ext4) et le monter ?" "o"; then
        mp="$(ask_mountpoint "  Point de montage")"
        plan_mount "$d" "$mp" 1
      fi
      continue
    fi

    mapfile -t devs < <(mountable_devs "$d")
    if (( ${#devs[@]} == 0 )); then
      tty_print "Disque non utilisé : $d ($size) — contenu non reconnu, ignoré (à traiter manuellement)."
      continue
    fi
    tty_print "Disque non utilisé : $d ($size) — contient déjà des données (aucun formatage ne sera fait)"
    for dev in "${devs[@]}"; do
      if ask_yn "  Monter $dev ($(dev_desc "$dev")) ?" "o"; then
        mp="$(ask_mountpoint "  Point de montage pour $dev")"
        plan_mount "$dev" "$mp" 0
      fi
    done
  done < <(list_disks)

  if (( ! found )); then tty_print "Aucun disque supplémentaire non monté détecté."; fi
}

# ----------------------------- Pré-requis ------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (ou via sudo)."
  # "curl | sudo bash" : sudo relaie mal le terminal quand son entrée est un pipe
  # (suspension du script à la 1re question sur Ubuntu 26.04 / sudo-rs)
  if [[ ! -t 0 && "$(ps -o comm= -p "$PPID" 2>/dev/null | tr -d ' ')" == sudo* ]]; then
    printf '%s\n' \
      "Mode \"curl | sudo bash\" non supporté (le terminal se bloque). Utilise :" \
      "  curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh -o bootstrap.sh" \
      "  sudo bash bootstrap.sh" >&2
    exit 1
  fi
  { : </dev/tty; } 2>/dev/null || die "Aucun terminal interactif disponible : lance le script depuis une session SSH/console."
  [[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "OS non supporté : ${ID:-inconnu} (Debian / Ubuntu uniquement)." ;;
  esac
  info "Système détecté : ${PRETTY_NAME:-$ID}"
}

# ----------------------------- Questions -------------------------------------
ask_questions() {
  section "Questions"

  # Compte admin
  while true; do
    ADMIN_USER="$(ask "Nom du compte administrateur")"
    if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      tty_print "  Nom invalide (minuscules, chiffres, _ et -, 32 caractères max)."; continue
    fi
    if [[ "$ADMIN_USER" == "root" ]]; then
      tty_print "  Choisis un autre nom que root."; continue
    fi
    if id "$ADMIN_USER" >/dev/null 2>&1; then
      if (( $(id -u "$ADMIN_USER") < 1000 )); then
        tty_print "  $ADMIN_USER est un compte système, choisis un autre nom."; continue
      fi
      ask_yn "  $ADMIN_USER existe déjà. Le mettre à jour ?" "n" || continue
      USER_EXISTS=1
    fi
    break
  done

  # Port SSH
  while true; do
    SSH_PORT="$(ask "Port SSH" "22")"
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )); then break; fi
    tty_print "  Port invalide (1-65535)."
  done

  # Nom d'hôte
  while true; do
    NEW_HOSTNAME="$(ask "Nom d'hôte (vide = ne pas changer, actuel : $(hostname))")"
    if [[ -z "$NEW_HOSTNAME" || "$NEW_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then break; fi
    tty_print "  Nom invalide (lettres, chiffres et -, 63 caractères max, sans point)."
  done

  # Disques supplémentaires
  ask_disks

  # Sudo
  if ask_yn "Sudo sans mot de passe pour $ADMIN_USER ?" "n"; then PASSWORDLESS_SUDO=1; fi

  # Clés SSH déjà présentes sur la machine (root et utilisateur sudo d'origine)
  local key_files=(/root/.ssh/authorized_keys) h f line found=()
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if [[ -n "$h" ]]; then key_files+=("$h/.ssh/authorized_keys"); fi
  fi
  for f in "${key_files[@]}"; do
    while IFS= read -r line; do
      if [[ -n "$line" ]] && is_valid_key "$line"; then found+=("$line"); fi
    done < <(extract_keys "$f")
  done
  if (( ${#found[@]} > 0 )); then
    tty_print "Clé(s) SSH trouvée(s) sur la machine :"
    for line in "${found[@]}"; do tty_print "  - $(key_label "$line")"; done
    if ask_yn "Autoriser ces clé(s) pour $ADMIN_USER ?" "o"; then
      for line in "${found[@]}"; do add_key "$line"; done
    fi
  fi

  # Clés supplémentaires
  while true; do
    line="$(ask "Clé publique SSH à ajouter (ligne complète, vide = terminer)")"
    [[ -z "$line" ]] && break
    if is_valid_key "$line"; then
      add_key "$line"; tty_print "  Clé ajoutée : $(key_label "$line")"
    else
      tty_print "  Clé invalide, ignorée."
    fi
  done

  # Clés déjà présentes chez l'utilisateur existant
  if (( USER_EXISTS )); then
    h="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    EXISTING_KEYS="$(extract_keys "$h/.ssh/authorized_keys" | grep -c . || true)"
  fi
  local total_keys=$(( ${#SSH_KEYS[@]} + EXISTING_KEYS ))

  # Durcissement SSH
  if (( total_keys > 0 )); then
    if ask_yn "Durcir SSH (connexion root interdite, mot de passe interdit, clés uniquement) ?" "o"; then HARDEN_SSH=1; fi
  else
    tty_print "  Aucune clé SSH : durcissement SSH impossible (tu serais verrouillé dehors)."
  fi

  # Mot de passe : obligatoire si sudo le demande ou si aucune clé SSH
  local required=0 p1 p2
  if (( ! PASSWORDLESS_SUDO || total_keys == 0 )); then required=1; fi
  while true; do
    if (( USER_EXISTS )); then
      p1="$(ask_secret "Nouveau mot de passe pour $ADMIN_USER (vide = inchangé)")"
      [[ -z "$p1" ]] && break
    elif (( required )); then
      p1="$(ask_secret "Mot de passe pour $ADMIN_USER")"
    else
      p1="$(ask_secret "Mot de passe pour $ADMIN_USER (vide = aucun, connexion par clé uniquement)")"
      [[ -z "$p1" ]] && break
    fi
    if (( ${#p1} < 8 )); then tty_print "  8 caractères minimum."; continue; fi
    p2="$(ask_secret "Confirmation")"
    if [[ "$p1" != "$p2" ]]; then tty_print "  Les mots de passe ne correspondent pas."; continue; fi
    ADMIN_PASS="$p1"
    break
  done

  # Récapitulatif
  section "Récapitulatif"
  local yn_sudo="non" yn_harden="non" pass_state="aucun"
  (( PASSWORDLESS_SUDO )) && yn_sudo="oui"
  (( HARDEN_SSH )) && yn_harden="oui"
  if [[ -n "$ADMIN_PASS" ]]; then pass_state="défini"; elif (( USER_EXISTS )); then pass_state="inchangé"; fi
  tty_print "  Compte admin      : $ADMIN_USER $( (( USER_EXISTS )) && echo '(existant, mis à jour)' || echo '(nouveau)')"
  tty_print "  Mot de passe      : $pass_state"
  tty_print "  Sudo sans mdp     : $yn_sudo"
  tty_print "  Clés SSH          : ${#SSH_KEYS[@]} ajoutée(s) + $EXISTING_KEYS existante(s)"
  tty_print "  Port SSH          : $SSH_PORT"
  tty_print "  Durcissement SSH  : $yn_harden"
  tty_print "  Nom d'hôte        : ${NEW_HOSTNAME:-inchangé ($(hostname))}"
  if (( ${#MOUNT_POINT[@]} == 0 )); then
    tty_print "  Disques           : aucun montage"
  else
    local i
    for i in "${!MOUNT_POINT[@]}"; do
      tty_print "  Disque            : ${MOUNT_DEV[$i]} -> ${MOUNT_POINT[$i]} $( (( MOUNT_FORMAT[i] )) && echo '(FORMATAGE : GPT + ext4)' || echo '(données conservées)')"
    done
  fi
  tty_print "  Fuseau horaire    : $TIMEZONE"
  tty_print "  Paquets           : ${PACKAGES[*]}"
  ask_yn "Lancer la configuration ?" "o" || die "Annulé, rien n'a été modifié."
}

# ----------------------------- Étapes ----------------------------------------
step_packages() {
  section "Paquets"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local apt_opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300)

  if command -v cloud-init >/dev/null 2>&1; then
    info "Attente de la fin de cloud-init..."
    cloud-init status --wait >/dev/null 2>&1 || true
  fi
  info "Mise à jour du système..."
  apt-get "${apt_opts[@]}" update </dev/null
  apt-get "${apt_opts[@]}" upgrade </dev/null
  info "Installation des paquets..."
  apt-get "${apt_opts[@]}" install "${PACKAGES[@]}" </dev/null
  ok "Paquets installés."
}

step_system() {
  section "Système"
  if [[ -n "$NEW_HOSTNAME" ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
    else
      printf '127.0.1.1 %s\n' "$NEW_HOSTNAME" >> /etc/hosts
    fi
    # Empêche cloud-init de remettre l'ancien nom au prochain reboot
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-bootstrap-hostname.cfg
    fi
    ok "Nom d'hôte : $NEW_HOSTNAME"
  fi
  timedatectl set-timezone "$TIMEZONE"
  ok "Fuseau horaire : $TIMEZONE"
}

step_user() {
  section "Compte administrateur"
  if (( ! USER_EXISTS )); then
    useradd -m -s /bin/bash "$ADMIN_USER"
    # '*' plutôt que '!' : pas de mot de passe, mais compte non verrouillé
    # (un compte '!' peut être refusé par sshd même avec une clé valide).
    usermod -p '*' "$ADMIN_USER"
    ok "Utilisateur $ADMIN_USER créé."
  fi
  if [[ -n "$ADMIN_PASS" ]]; then
    printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd
    ok "Mot de passe défini."
  fi

  local g
  for g in sudo adm systemd-journal; do
    if getent group "$g" >/dev/null; then usermod -aG "$g" "$ADMIN_USER"; fi
  done
  ok "Groupes : $(id -nG "$ADMIN_USER")"

  local sudo_file="/etc/sudoers.d/90-bootstrap-$ADMIN_USER" tmp
  if (( PASSWORDLESS_SUDO )); then
    tmp="$(mktemp)"
    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$tmp"
    if visudo -cqf "$tmp"; then
      install -m 0440 -o root -g root "$tmp" "$sudo_file"
      rm -f "$tmp"
      ok "Sudo sans mot de passe activé."
    else
      rm -f "$tmp"
      die "Règle sudoers invalide, non appliquée."
    fi
  else
    rm -f "$sudo_file"
  fi
}

step_ssh_keys() {
  section "Clés SSH"
  local home group ak tmp
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  group="$(id -gn "$ADMIN_USER")"
  ak="$home/.ssh/authorized_keys"

  install -d -m 700 -o "$ADMIN_USER" -g "$group" "$home/.ssh"
  tmp="$(mktemp)"
  {
    if [[ -f "$ak" ]]; then cat "$ak"; fi
    if (( ${#SSH_KEYS[@]} > 0 )); then printf '%s\n' "${SSH_KEYS[@]}"; fi
  } | awk 'NF && !seen[$0]++' > "$tmp"
  install -m 600 -o "$ADMIN_USER" -g "$group" "$tmp" "$ak"
  rm -f "$tmp"
  ok "$(grep -c . "$ak" || true) clé(s) dans $ak"
}

step_disks() {
  (( ${#MOUNT_POINT[@]} > 0 )) || return 0
  section "Disques"
  local i dev mp part fs uuid label pass
  [[ -f /etc/fstab.bak-bootstrap ]] || cp -a /etc/fstab /etc/fstab.bak-bootstrap

  for i in "${!MOUNT_POINT[@]}"; do
    dev="${MOUNT_DEV[$i]}"; mp="${MOUNT_POINT[$i]}"

    if (( MOUNT_FORMAT[i] )); then
      # Contrôle de sécurité : le disque doit toujours être vierge et inutilisé
      disk_is_busy "$dev" && die "$dev est maintenant utilisé, formatage annulé."
      disk_is_empty "$dev" || die "$dev n'est plus vierge, formatage annulé."
      info "Partitionnement de $dev (GPT, une partition)..."
      printf 'label: gpt\n,\n' | sfdisk -q "$dev"
      part=""
      for _ in $(seq 1 10); do
        udevadm settle 2>/dev/null || true
        part="$(lsblk -nrpo NAME,TYPE "$dev" | awk '$2 == "part" { print $1; exit }')"
        [[ -n "$part" && -b "$part" ]] && break
        sleep 1
      done
      [[ -n "$part" && -b "$part" ]] || die "Partition de $dev introuvable après partitionnement."
      label="$(printf '%s' "$(basename "$mp")" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-16)"
      info "Formatage de $part en ext4 (label $label)..."
      mkfs.ext4 -q -m 1 -L "$label" "$part"
      dev="$part"
      MOUNT_DEV[i]="$part"
    fi

    uuid="$(blkid -s UUID -o value "$dev" || true)"
    fs="$(blkid -s TYPE -o value "$dev" || true)"
    [[ -n "$uuid" && -n "$fs" ]] || die "UUID ou type de système de fichiers introuvable pour $dev."
    MOUNT_UUID[i]="$uuid"
    pass=0; [[ "$fs" == ext* ]] && pass=2

    mkdir -p "$mp"
    # Retire une éventuelle ancienne ligne pour ce même système de fichiers
    sed -i "\|^UUID=${uuid}[[:space:]]|d" /etc/fstab
    # nofail : le serveur démarre même si le disque est absent
    printf 'UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=10s 0 %s\n' "$uuid" "$mp" "$fs" "$pass" >> /etc/fstab
    systemctl daemon-reload
    mount "$mp"
    ok "$dev ($fs) monté sur $mp, montage automatique au démarrage."
  done
}

step_firewall() {
  section "Pare-feu UFW"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  ufw --force enable
  ok "UFW actif, port $SSH_PORT/tcp ouvert."
}

reload_ssh() {
  # Ubuntu 22.10+ : SSH activé par socket systemd, le port est lu par un générateur
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl try-reload-or-restart ssh.service
  else
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
  fi
}

step_ssh() {
  section "Serveur SSH"
  mkdir -p /etc/ssh/sshd_config.d /run/sshd

  # Sauvegarde unique de la config d'origine
  [[ -f "$SSHD_MAIN.bak-bootstrap" ]] || cp -a "$SSHD_MAIN" "$SSHD_MAIN.bak-bootstrap"

  # La directive Port est cumulative : on neutralise celles du fichier principal
  sed -i -E 's/^([[:space:]]*Port[[:space:]]+)/# bootstrap: \1/' "$SSHD_MAIN"

  # S'assure que les fichiers sshd_config.d sont lus
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_MAIN"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_MAIN"
  fi

  # Préfixe 00- : pour les autres directives, sshd garde la première valeur lue
  # (passe donc avant 50-cloud-init.conf qui réactive souvent les mots de passe)
  {
    echo "# Géré par bootstrap.sh"
    echo "Port $SSH_PORT"
    if (( HARDEN_SSH )); then
      echo "PermitRootLogin no"
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "PubkeyAuthentication yes"
      echo "MaxAuthTries 3"
      echo "X11Forwarding no"
    fi
  } > "$SSHD_DROPIN"
  chmod 644 "$SSHD_DROPIN"

  if ! /usr/sbin/sshd -t; then
    rm -f "$SSHD_DROPIN"
    cp -a "$SSHD_MAIN.bak-bootstrap" "$SSHD_MAIN"
    die "Configuration SSH invalide, configuration d'origine restaurée."
  fi

  reload_ssh

  local _
  for _ in $(seq 1 10); do
    if ss -Hltn "sport = :$SSH_PORT" | grep -q .; then break; fi
    sleep 1
  done
  ok "SSH rechargé (port $SSH_PORT, durci : $( (( HARDEN_SSH )) && echo oui || echo non))."
}

step_fail2ban() {
  section "fail2ban"
  cat > "$F2B_JAIL" <<EOF
# Géré par bootstrap.sh
[DEFAULT]
bantime            = 1h
findtime           = 10m
maxretry           = 5
banaction          = ufw
banaction_allports = ufw

[sshd]
enabled = true
backend = systemd
port    = $SSH_PORT
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban

  local _
  for _ in $(seq 1 15); do
    if fail2ban-client ping >/dev/null 2>&1; then break; fi
    sleep 1
  done
  ok "fail2ban redémarré."
}

step_autoupdates() {
  section "Mises à jour automatiques"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  ok "Mises à jour de sécurité automatiques activées."
}

# ----------------------------- Vérification ----------------------------------
check() { # check "Libellé" commande...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$label"
  else
    printf '  %s[KO]%s %s\n' "$C_RED" "$C_RESET" "$label"
    FAILS=$((FAILS + 1))
  fi
}

sshd_val()        { /usr/sbin/sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }'; }
chk_in_group()    { id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx "$1"; }
chk_sudo()        { sudo -l -U "$ADMIN_USER" | grep -q '(ALL'; }
chk_nopasswd()    { sudo -l -U "$ADMIN_USER" | grep -q 'NOPASSWD: ALL'; }
chk_perm()        { [[ "$(stat -c '%a %U' "$1")" == "$2 $ADMIN_USER" ]]; }
chk_has_keys()    { [[ -n "$(extract_keys "$1")" ]]; }
chk_sshd_port()   { [[ "$(sshd_val port)" == "$SSH_PORT" ]]; }
chk_sshd_eq()     { [[ "$(sshd_val "$1")" == "$2" ]]; }
chk_listening()   { ss -Hltn "sport = :$SSH_PORT" | grep -q .; }
chk_ufw_active()  { ufw status | grep -q '^Status: active'; }
chk_ufw_rule()    { ufw status | grep -qE "^${SSH_PORT}/tcp[[:space:]]+ALLOW"; }
chk_f2b_jail()    { fail2ban-client status sshd; }
chk_autoupd()     { apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; }
chk_timezone()    { [[ "$(timedatectl show -p Timezone --value)" == "$TIMEZONE" ]]; }
chk_hostname()    { [[ "$(hostname)" == "$NEW_HOSTNAME" ]]; }
chk_pkg()         { dpkg-query -W -f='${Status}' "$1" | grep -q 'install ok installed'; }

verify() {
  section "Vérification"
  local home ak p missing=()
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  ak="$home/.ssh/authorized_keys"

  for p in "${PACKAGES[@]}"; do chk_pkg "$p" >/dev/null 2>&1 || missing+=("$p"); done
  check "Paquets installés${missing[*]:+ (manquants : ${missing[*]})}" test ${#missing[@]} -eq 0

  check "Utilisateur $ADMIN_USER existe"            id "$ADMIN_USER"
  check "$ADMIN_USER dans le groupe sudo"            chk_in_group sudo
  check "$ADMIN_USER dans le groupe adm"             chk_in_group adm
  check "Droits sudo effectifs"                      chk_sudo
  if (( PASSWORDLESS_SUDO )); then
    check "Sudo sans mot de passe"                   chk_nopasswd
  fi
  check ".ssh en 700"                                chk_perm "$home/.ssh" 700
  check "authorized_keys en 600"                     chk_perm "$ak" 600
  if (( HARDEN_SSH )) || (( ${#SSH_KEYS[@]} > 0 )); then
    check "authorized_keys contient au moins une clé" chk_has_keys "$ak"
  fi

  check "Config sshd valide"                         /usr/sbin/sshd -t
  check "sshd configuré sur le port $SSH_PORT uniquement" chk_sshd_port
  check "sshd écoute sur le port $SSH_PORT"          chk_listening
  if (( HARDEN_SSH )); then
    check "Connexion root interdite"                 chk_sshd_eq permitrootlogin no
    check "Authentification par mot de passe coupée" chk_sshd_eq passwordauthentication no
    check "Authentification par clé active"          chk_sshd_eq pubkeyauthentication yes
  fi

  check "UFW actif"                                  chk_ufw_active
  check "UFW autorise $SSH_PORT/tcp"                 chk_ufw_rule
  check "fail2ban actif"                             systemctl is-active --quiet fail2ban
  check "Jail fail2ban sshd chargée"                 chk_f2b_jail
  check "Mises à jour automatiques"                  chk_autoupd
  check "Fuseau horaire $TIMEZONE"                   chk_timezone
  local i
  for i in "${!MOUNT_POINT[@]}"; do
    check "Disque monté sur ${MOUNT_POINT[$i]}"      findmnt -n "${MOUNT_POINT[$i]}"
    check "Montage ${MOUNT_POINT[$i]} dans fstab"    grep -qE "^UUID=${MOUNT_UUID[$i]:-none}[[:space:]]+${MOUNT_POINT[$i]}[[:space:]]" /etc/fstab
  done

  if [[ -n "$NEW_HOSTNAME" ]]; then
    check "Nom d'hôte $NEW_HOSTNAME"                 chk_hostname
  fi
}

# ----------------------------- Programme principal ---------------------------
main() {
  preflight
  ask_questions

  # Journalisation à partir d'ici (les mots de passe ne sont jamais affichés)
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '\n===== bootstrap %s =====\n' "$(date '+%F %T')"

  EXEC_PHASE=1
  STEP_TOTAL=9
  if (( ${#MOUNT_POINT[@]} > 0 )); then STEP_TOTAL=10; fi

  step_packages
  step_system
  step_disks
  step_user
  step_ssh_keys
  step_firewall      # avant SSH : le nouveau port est ouvert avant d'être utilisé
  step_ssh
  step_fail2ban
  step_autoupdates
  verify

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "=============================================================="
  if (( FAILS == 0 )); then
    echo " ${C_GREEN}Configuration terminée, toutes les vérifications sont OK.${C_RESET}"
  else
    echo " ${C_RED}Configuration terminée avec $FAILS vérification(s) en échec.${C_RESET}"
    echo " Détails dans $LOG_FILE"
  fi
  echo
  echo " ==> TESTE dans un NOUVEAU terminal avant de fermer cette session :"
  echo "     ssh -p $SSH_PORT $ADMIN_USER@${ip:-<ip>}"
  if [[ "$SSH_PORT" != "22" ]]; then
    echo "     (pense à ouvrir le port $SSH_PORT dans le pare-feu de l'hébergeur)"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    echo
    echo " ${C_YELLOW}Redémarrage requis${C_RESET} (noyau ou bibliothèques mis à jour) :"
    echo "     sudo reboot   (après avoir testé la connexion SSH)"
  fi
  echo "=============================================================="
  if (( FAILS > 0 )); then exit 1; fi
}

# Tout le script est lu avant exécution (sécurité avec "curl | bash")
main "$@"
