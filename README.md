# Ubuntu-serv-setup

Script de configuration initiale d'un serveur **Debian / Ubuntu** (cloud ou VM), lançable en une commande.

## Lancement

Terminal interactif obligatoire (session SSH ou console).

Depuis le compte par défaut d'une image cloud (`ubuntu`, `debian`…) :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh
```

Déjà en root (`sudo -i`) :

```bash
curl -fsSL https://raw.githubusercontent.com/bapt-git/Ubuntu-serv-setup/main/bootstrap.sh | bash
```

> [!warning] Ne pas utiliser `curl … | sudo bash`
> Sur Ubuntu 26.04 (`sudo-rs`), le script est suspendu dès la 2ᵉ question : `sudo` relaie mal le terminal quand son entrée est un pipe. Le script détecte ce cas et s'arrête avec la bonne commande.

Pendant l'exécution, chaque étape affiche sa progression et l'heure : `== [3/10 15:18:42] Disques ==`. Un redémarrage est signalé à la fin si une mise à jour l'exige.

## Déroulement

1. **Questions** : compte admin, port SSH, nom d'hôte, disques supplémentaires, sudo sans mot de passe, clés SSH, durcissement SSH, mot de passe
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

## Disques supplémentaires

Le script liste les disques **non utilisés** (rien de monté dessus, pas membre LVM/RAID/LUKS, plus de 1 Gio, hors zram/loop/lecteurs optiques) et propose de les monter :

| État du disque | Action proposée |
|---|---|
| Vierge (ni partition ni système de fichiers) | GPT + une partition + **ext4**, puis montage |
| Contient un système de fichiers (ext2/3/4, xfs, btrfs) | Montage **sans formatage**, données conservées |
| Autre contenu (LVM inactif, NTFS, partitions sans FS…) | Ignoré, à traiter manuellement |

- Point de montage demandé (défaut `/data`, puis `/data2`…), refusé s'il s'agit d'un dossier système, d'un dossier non vide ou d'un chemin déjà monté
- Montage automatique via `/etc/fstab` par **UUID**, avec `nofail` : le serveur démarre même si le disque est absent
- Juste avant le formatage, le script revérifie que le disque est toujours vierge
- Sauvegarde : `/etc/fstab.bak-bootstrap`
- Le point de montage appartient à root : `chown` à faire selon l'usage

Agrandir plus tard un disque formaté par le script (après extension côté hyperviseur) :

```bash
sudo apt install cloud-guest-utils
sudo growpart /dev/sdb 1
sudo resize2fs /dev/sdb1
```

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
| `/etc/fstab` | Montages des disques (sauvegarde : `fstab.bak-bootstrap`) |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Mises à jour automatiques |
| `/etc/cloud/cloud.cfg.d/99-bootstrap-hostname.cfg` | Conservation du nom d'hôte |

Le script peut être relancé sur une machine déjà configurée.

## Après exécution

Tester la connexion dans un **nouveau terminal** avant de fermer la session en cours :

```bash
ssh -p <port> <admin>@<ip>
```

En cas de changement de port SSH, l'ouvrir aussi dans le pare-feu de l'hébergeur.

### Supprimer le compte fourni par l'image cloud

Les images cloud créent un compte par défaut (`ubuntu`, `debian`…) avec **sudo sans mot de passe**. Le script ne le supprime pas : une fois la connexion avec le compte admin validée (et `sudo` testé), le supprimer depuis le compte admin :

```bash
sudo deluser --remove-home ubuntu
sudo rm -f /etc/sudoers.d/90-cloud-init-users
```

### Vérifier quelle clé est utilisée

Si plusieurs clés sont autorisées, retrouver celle d'une session :

```bash
echo $SSH_CLIENT                                   # 2e valeur = port source de la session
sudo journalctl --since today | grep "Accepted publickey"   # port -> empreinte SHA256
ssh-keygen -lf ~/.ssh/authorized_keys              # empreinte -> commentaire de la clé
```

Supprimer une clé inutile en restant connecté avec celle à garder, puis tester une nouvelle connexion avant de fermer la session.
