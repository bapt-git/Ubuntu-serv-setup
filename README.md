# Ubuntu-serv-setup

Script de configuration initiale d'un serveur **Debian / Ubuntu** (cloud ou VM), lançable en une commande.

## Lancement

En root, depuis une session SSH ou console (terminal interactif obligatoire) :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | bash
```

Depuis le compte par défaut d'une image cloud (`ubuntu`, `debian`…) :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | sudo bash
```

## Déroulement

1. **Questions** : compte admin, port SSH, nom d'hôte, sudo sans mot de passe, clés SSH, durcissement SSH, mot de passe
2. **Récapitulatif** et confirmation - rien n'est modifié avant
3. **Exécution** sans interruption
4. **Vérification** point par point (`[OK]` / `[KO]`)

## Ce que fait le script

- Mise à jour du système (attend la fin de cloud-init, sans question dpkg/needrestart)
- Compte admin : création, groupes `sudo`, `adm`, `systemd-journal`, mot de passe
- Sudo avec ou sans mot de passe (règle validée par `visudo` avant application)
- Clés SSH :
  - propose les clés déjà présentes chez root et chez l'utilisateur qui a lancé `sudo` (préfixes cloud `command="Please login as..."` retirés)
  - ajout de clés collées, validées par `ssh-keygen`
  - `~/.ssh` en 700, `authorized_keys` en 600
- Paquets : `sudo`, `openssh-server`, `ufw`, `fail2ban`, `python3-systemd`, `unattended-upgrades`, `htop`, `curl`, `wget`, `git`, `nano`, `ncdu`, `tmux`, `unzip`, `rsync`, `ca-certificates`, `gnupg`
- UFW : entrant bloqué, port SSH ouvert (configuré **avant** le changement de port)
- SSH : port configurable, gère l'activation par socket d'Ubuntu 22.10+, config testée par `sshd -t` et restaurée si invalide
- fail2ban : jail `sshd` (backend systemd), bannissement via UFW
- Nom d'hôte (persistant malgré cloud-init), fuseau `Europe/Paris`
- Mises à jour de sécurité automatiques
- Log : `/var/log/bootstrap.log` (mots de passe jamais journalisés)

## Durcissement SSH

Proposé uniquement si au moins une clé SSH est autorisée (sinon risque de se verrouiller dehors). Il applique :

| Directive | Valeur | Effet |
|---|---|---|
| `PermitRootLogin` | `no` | Connexion directe en root interdite |
| `PasswordAuthentication` | `no` | Mot de passe refusé en SSH |
| `KbdInteractiveAuthentication` | `no` | Pas de saisie interactive (contourne sinon le point précédent) |
| `PubkeyAuthentication` | `yes` | Connexion par clé uniquement |
| `MaxAuthTries` | `3` | 3 essais par connexion |
| `X11Forwarding` | `no` | Pas de déport graphique |

Le mot de passe du compte reste utile pour `sudo` et la console de l'hébergeur.

## Fichiers modifiés

| Fichier | Rôle |
|---|---|
| `/etc/ssh/sshd_config.d/00-bootstrap.conf` | Port + durcissement SSH |
| `/etc/ssh/sshd_config` | Lignes `Port` commentées (sauvegarde : `sshd_config.bak-bootstrap`) |
| `/etc/sudoers.d/90-bootstrap-<user>` | Sudo sans mot de passe (si choisi) |
| `/etc/fail2ban/jail.d/10-bootstrap.local` | Jail fail2ban |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Mises à jour automatiques |
| `/etc/cloud/cloud.cfg.d/99-bootstrap-hostname.cfg` | Conservation du nom d'hôte |

Le script peut être relancé sur une machine déjà configurée.

## Après exécution

Tester la connexion dans un **nouveau terminal** avant de fermer la session en cours :

```bash
ssh -p <port> <admin>@<ip>
```

En cas de changement de port SSH, l'ouvrir aussi dans le pare-feu de l'hébergeur.
