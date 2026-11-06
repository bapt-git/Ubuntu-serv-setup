#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - Configuration initiale d'un serveur Debian / Ubuntu
#
# Usage (en root) :
#   curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | bash
#
# Mode non interactif (variables d'environnement) :
#   ADMIN_USER=baptiste SSH_PORT=22 SSH_PUBKEY="ssh-ed25519 AAAA..." \
#   HARDEN_SSH=yes NONINTERACTIVE=1 bash bootstrap.sh
# =============================================================================
set -Eeuo pipefail

# ----------------------------- Paramètres par défaut -------------------------
TIMEZONE="${TIMEZONE:-Europe/Paris}"
SSH_PORT="${SSH_PORT:-22}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-htop curl wget git vim nano ncdu tmux unzip rsync ca-certificates gnupg}"
LOG_FILE="/var/log/bootstrap.log"

# ----------------------------- Affichage -------------------------------------
C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
info()  { echo "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()    { echo "${C_GREEN}[ OK ]${C_RESET}  $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*"; }
die()   { echo "${C_RED}[ERR ]${C_RESET}  $*" >&2; exit 1; }
trap 'die "Erreur ligne $LINENO (commande : $BASH_COMMAND)"' ERR

exec > >(tee -a "$LOG_FILE") 2>&1

# ----------------------------- Vérifications ---------------------------------
[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root (ou via sudo)."

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "OS non supporté : ${ID:-inconnu} (Debian / Ubuntu uniquement)." ;;
esac
info "Système détecté : ${PRETTY_NAME}"

# ----------------------------- Entrées utilisateur ---------------------------
# Lecture sur /dev/tty pour fonctionner avec "curl | bash"
ask() { # ask "Question" "défaut" -> echo réponse
  local prompt="$1" default="${2:-}" reply=""
  if [[ "${NONINTERACTIVE:-0}" == "1" ]] || [[ ! -r /dev/tty ]]; then
    echo "$default"; return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default] : " reply < /dev/tty || true
  else
    read -r -p "$prompt : " reply < /dev/tty || true
  fi
  echo "${reply:-$default}"
}

ask_yn() { # ask_yn "Question" "yes|no" -> 0 si oui
  local r; r="$(ask "$1 (yes/no)" "$2")"
  [[ "${r,,}" =~ ^(y|yes|o|oui)$ ]]
}

ADMIN_USER="${ADMIN_USER:-}"
if [[ -z "$ADMIN_USER" ]]; then
  ADMIN_USER="$(ask "Nom du compte administrateur à créer" "")"
fi
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Nom d'utilisateur invalide : '$ADMIN_USER'"
[[ "$ADMIN_USER" != "root" ]] || die "Choisis un autre nom que root."

SSH_PORT="$(ask "Port SSH" "$SSH_PORT")"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Port SSH invalide."

NEW_HOSTNAME="${NEW_HOSTNAME:-}"
if [[ -z "$NEW_HOSTNAME" ]]; then
  NEW_HOSTNAME="$(ask "Nom d'hôte (vide = ne pas changer)" "")"
fi

# ----------------------------- Paquets ---------------------------------------
export DEBIAN_FRONTEND=noninteractive
info "Mise à jour de l'index et du système..."
apt-get update -y
apt-get upgrade -y

info "Installation des paquets..."
# shellcheck disable=SC2086
apt-get install -y sudo ufw fail2ban unattended-upgrades $EXTRA_PACKAGES
ok "Paquets installés."

# ----------------------------- Hostname / timezone ---------------------------
if [[ -n "$NEW_HOSTNAME" ]]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
  else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
  fi
  ok "Nom d'hôte : $NEW_HOSTNAME"
fi

timedatectl set-timezone "$TIMEZONE" && ok "Fuseau horaire : $TIMEZONE"

# ----------------------------- Compte admin ----------------------------------
if id "$ADMIN_USER" &>/dev/null; then
  warn "L'utilisateur $ADMIN_USER existe déjà, il sera simplement mis à jour."
else
  adduser --disabled-password --gecos "" "$ADMIN_USER"
  ok "Utilisateur $ADMIN_USER créé."
fi

# Groupes : sudo + adm (lecture des logs) + systemd-journal si présents
for g in sudo adm systemd-journal; do
  if getent group "$g" >/dev/null; then
    usermod -aG "$g" "$ADMIN_USER"
  fi
done
ok "Groupes de $ADMIN_USER : $(id -nG "$ADMIN_USER")"

# Mot de passe (utile pour sudo si pas de NOPASSWD)
PASSWORDLESS_SUDO="${PASSWORDLESS_SUDO:-}"
if [[ -z "$PASSWORDLESS_SUDO" ]]; then
  if ask_yn "Sudo sans mot de passe pour $ADMIN_USER ?" "no"; then
    PASSWORDLESS_SUDO="yes"
  else
    PASSWORDLESS_SUDO="no"
  fi
fi

if [[ "$PASSWORDLESS_SUDO" == "yes" ]]; then
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
  chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
  visudo -cf "/etc/sudoers.d/90-$ADMIN_USER" >/dev/null
  ok "Sudo sans mot de passe activé."
elif [[ "${NONINTERACTIVE:-0}" != "1" && -r /dev/tty ]]; then
  info "Définis le mot de passe de $ADMIN_USER :"
  passwd "$ADMIN_USER" < /dev/tty
fi

# ----------------------------- Clés SSH --------------------------------------
USER_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SSH_DIR"
touch "$AUTH_KEYS"

SSH_PUBKEY="${SSH_PUBKEY:-}"
if [[ -z "$SSH_PUBKEY" ]]; then
  SSH_PUBKEY="$(ask "Clé publique SSH à autoriser (coller la ligne complète, vide = copier celle de root si elle existe)" "")"
fi

if [[ -n "$SSH_PUBKEY" ]]; then
  grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS" || echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
  ok "Clé publique ajoutée."
elif [[ -s /root/.ssh/authorized_keys ]]; then
  cat /root/.ssh/authorized_keys >> "$AUTH_KEYS"
  sort -u "$AUTH_KEYS" -o "$AUTH_KEYS"
  ok "Clés de root copiées vers $ADMIN_USER."
else
  warn "Aucune clé SSH ajoutée."
fi

chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
HAS_KEY=0; [[ -s "$AUTH_KEYS" ]] && HAS_KEY=1

# ----------------------------- Durcissement SSH ------------------------------
HARDEN_SSH="${HARDEN_SSH:-}"
if [[ -z "$HARDEN_SSH" ]]; then
  if (( HAS_KEY )) && ask_yn "Durcir SSH (root interdit, authentification par mot de passe désactivée) ?" "yes"; then
    HARDEN_SSH="yes"
  else
    HARDEN_SSH="no"
  fi
fi

if [[ "$HARDEN_SSH" == "yes" ]]; then
  (( HAS_KEY )) || die "Durcissement SSH refusé : aucune clé publique installée (tu serais verrouillé dehors)."
  mkdir -p /etc/ssh/sshd_config.d
  # Préfixe 00- : sshd garde la première valeur lue (passe avant 50-cloud-init.conf)
  cat > /etc/ssh/sshd_config.d/00-bootstrap.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
EOF
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    ok "SSH durci (port $SSH_PORT)."
  else
    rm -f /etc/ssh/sshd_config.d/00-bootstrap.conf
    die "Configuration SSH invalide, modification annulée."
  fi
elif [[ "$SSH_PORT" != "22" ]]; then
  mkdir -p /etc/ssh/sshd_config.d
  echo "Port $SSH_PORT" > /etc/ssh/sshd_config.d/00-bootstrap.conf
  sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }
  ok "Port SSH changé : $SSH_PORT"
fi

# ----------------------------- UFW -------------------------------------------
info "Configuration du pare-feu UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
# On garde aussi le 22 ouvert tant que le port n'a pas été validé
if [[ "$SSH_PORT" != "22" ]]; then
  warn "Port 22 non ouvert dans UFW. Teste la connexion sur le port $SSH_PORT avant de fermer ta session actuelle."
fi
ufw --force enable
ok "UFW actif."

# ----------------------------- Fail2ban --------------------------------------
info "Configuration de fail2ban..."
cat > /etc/fail2ban/jail.d/10-bootstrap.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
ok "fail2ban actif."

# ----------------------------- Mises à jour auto -----------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
ok "Mises à jour de sécurité automatiques activées."

# ----------------------------- Récapitulatif ---------------------------------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "=============================================================="
echo " Configuration terminée"
echo "--------------------------------------------------------------"
echo " Utilisateur : $ADMIN_USER   (groupes : $(id -nG "$ADMIN_USER"))"
echo " SSH         : port $SSH_PORT, durci = $HARDEN_SSH"
echo " Pare-feu    : $(ufw status | head -1)"
echo " fail2ban    : $(systemctl is-active fail2ban)"
echo " Log         : $LOG_FILE"
echo
echo " ==> TESTE dans un NOUVEAU terminal avant de fermer cette session :"
echo "     ssh -p $SSH_PORT $ADMIN_USER@${IP:-<ip>}"
echo "=============================================================="
