# Ubuntu-serv-setup

Script de configuration initiale d'un serveur **Debian / Ubuntu** (cloud ou VM), lançable en une commande.

## Lancement

En root sur la nouvelle machine :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | bash
```

Mode non interactif :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh -o bootstrap.sh
ADMIN_USER=baptiste SSH_PUBKEY="ssh-ed25519 AAAA..." HARDEN_SSH=yes \
PASSWORDLESS_SUDO=no NONINTERACTIVE=1 bash bootstrap.sh
```

## Ce que fait le script

- Mise à jour du système
- Création du compte admin (nom demandé), ajout aux groupes `sudo`, `adm`, `systemd-journal`
- Sudo avec ou sans mot de passe (au choix)
- Création de `~/.ssh` + `authorized_keys` (clé collée ou copiée depuis root)
- Paquets : `sudo`, `ufw`, `fail2ban`, `unattended-upgrades`, `htop`, `curl`, `wget`, `git`, `vim`, `nano`, `ncdu`, `tmux`, `unzip`, `rsync`
- UFW : entrant bloqué, port SSH ouvert
- fail2ban : jail `sshd` (backend systemd)
- Durcissement SSH optionnel : root interdit, mot de passe désactivé (uniquement si une clé est présente)
- Hostname (optionnel), fuseau `Europe/Paris`, mises à jour de sécurité automatiques
- Log : `/var/log/bootstrap.log`

## Variables

| Variable | Défaut | Rôle |
|---|---|---|
| `ADMIN_USER` | *(demandé)* | Compte admin à créer |
| `SSH_PORT` | `22` | Port SSH |
| `SSH_PUBKEY` | *(demandé)* | Clé publique à autoriser |
| `NEW_HOSTNAME` | *(demandé)* | Nom d'hôte, vide = inchangé |
| `HARDEN_SSH` | *(demandé)* | `yes` / `no` |
| `PASSWORDLESS_SUDO` | *(demandé)* | `yes` / `no` |
| `TIMEZONE` | `Europe/Paris` | Fuseau horaire |
| `EXTRA_PACKAGES` | voir script | Paquets additionnels |
| `NONINTERACTIVE` | `0` | `1` = aucune question |

## Après exécution

Tester la connexion dans un **nouveau terminal** avant de fermer la session root :

```bash
ssh -p <port> <admin>@<ip>
```

En cas de changement de port SSH, l'ouvrir aussi dans le pare-feu de l'hébergeur.
