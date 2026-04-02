# Deployment install guide (step-by-step)

Target: **Ubuntu 24.04** (or similar) staging server. Run commands **as root** via `sudo` where shown.

**GitHub layout:** this stack lives under **[zartashtech/scripts](https://github.com/zartashtech/scripts)** in folder **`lamp-php8.4-mysql8.4-mutisite/`** (i.e. `zartashtech/scripts/lamp-php8.4-mysql8.4-mutisite` in the tree). After cloning the repo, **always `cd` into that folder** before running any deploy script; all paths below use that as the project root (example: `/opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite`).

---

## 0. Clone the repository on the server

```bash
sudo mkdir -p /opt/deploy
sudo chown "$USER:$USER" /opt/deploy
cd /opt/deploy
git clone git@github.com:zartashtech/scripts.git
cd scripts/lamp-php8.4-mysql8.4-mutisite
```

Using HTTPS instead of SSH for the clone:

```bash
git clone https://github.com/zartashtech/scripts.git
cd scripts/lamp-php8.4-mysql8.4-mutisite
```

If you only copy files (no git remote), unpack so this folder contains `deploy/scripts/` and `deploy/config/`.

---

## 1. GitHub SSH access for the **private websites** monorepo

The app code lives in a **separate** private repository. Configure SSH on the server:

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo ./github_setup.sh <github_org_or_user> <private_repo_name>
```

Copy the printed **public** key into GitHub: **Repository → Settings → Deploy keys** (read-only is enough).

Set `deploy/config/settings.conf`:

- `github_repo_ssh_url` — must match the SSH URL (including any host alias from `github_setup.sh`, e.g. `git@github-mysite:org/repo.git`).

Test (as root, if deploy runs as root):

```bash
sudo git ls-remote "$(grep '^github_repo_ssh_url=' deploy/config/settings.conf | cut -d= -f2- | tr -d '"')"
```

---

## 2. Edit configuration and inventories

Edit these files before any provisioning:

| File | Purpose |
|------|---------|
| `deploy/config/settings.conf` | Repo URL, `local_repo_path`, `purge_inactive`, `dry_run`, `ssh_db_identity_file`, paths |
| `deploy/config/site_inventory.ini` | Per-site `website_id` (section name), `domain`, `repo_folder`, `branch`, `active`, SSL options |
| `deploy/config/db_inventory.ini` | `[local_db:*]`, `[source:*]`, `[map:*]` for shared DBs and dumps |

Notes:

- Section name in `site_inventory.ini` **is** the `website_id`; live tree is always `/home/<website_id>/`.
- For first-time setup you may set `purge_inactive="no"` in `settings.conf` until you are sure inventory is correct (avoids deleting sites marked `active=no`).

---

## 3. One-time server bootstrap (Apache, PHP 8.4 FPM, MySQL 8.4)

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo bash deploy/scripts/server_bootstrap.sh
```

Sets non-interactive apt/dpkg behavior where applicable. Secure MySQL (`mysql_secure_installation` or equivalent) as needed for your policy.

---

## 4. Provision Apache vhosts, docroots, SSL (Certbot) — one-time per inventory change

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo bash deploy/scripts/site_provision.sh
```

Re-run after adding sites or changing domains/SSL. With `purge_inactive=yes`, `deploy.sh` / `site_provision.sh` can also tear down inactive/orphan sites (see `deploy/README.md`).

---

## 5. SSH key for database pulls (staging → source servers)

On **staging**:

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo bash deploy/scripts/ssh_db_bootstrap.sh
```

This uses `ssh_db_identity_file` from `settings.conf` and tests every `[source:*]` in `db_inventory.ini`.

On **each source** host, install the helper and authorize the **same** public key (as the `ssh_user` from inventory):

```bash
# copy deploy/scripts/remote_ssh_connect_provision.sh to the source, then:
sudo bash remote_ssh_connect_provision.sh
```

Non-interactive example (staging → source as `root`):

```bash
printf '%s\n' "$(sudo cat /root/.ssh/db_pull_ed25519.pub)" | TARGET_USER=root sudo -E bash remote_ssh_connect_provision.sh
```

Ensure **`mysql_defaults_file`** on the source (often `/root/.my.cnf`) allows `mysqldump` for the databases you export.

Re-run `ssh_db_bootstrap.sh` until all sources report success.

---

## 6. Create local databases, users, and import from sources

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo bash deploy/scripts/db_provision.sh
```

Imports use `mysqldump` over SSH and import into the **`db_name`** from the matching `[local_db:*]` block (not only the section label).

---

## 7. Deploy application code (repeatable)

Full deploy (validate, optional purge, sync repo, rsync all `active=yes` sites):

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo bash deploy/scripts/deploy.sh
```

Useful variants:

```bash
sudo bash deploy/scripts/deploy.sh --site <website_id>
sudo bash deploy/scripts/deploy.sh --inventory deploy/config/site_inventory.ini
sudo bash deploy/scripts/deploy.sh --verbose
```

---

## 8. Dry run

In `deploy/config/settings.conf` set:

```bash
dry_run="yes"
```

Then run `deploy.sh`. Repo fetch still runs; rsync uses dry-run (`-n`). Set back to `no` for real deploys.

---

## 9. Logs and locks

- Deploy logs: `deploy/logs/deploy-*.log`
- DB logs: `deploy/logs/db-*.log`
- If a run died with the lock held, confirm no deploy is running, then remove `deploy/tmp/deploy.lock`.

---

## 10. Suggested first-time order (checklist)

1. Clone `zartashtech/scripts` and `cd` into `lamp-php8.4-mysql8.4-mutisite`.
2. `github_setup.sh` + deploy key on GitHub + `github_repo_ssh_url` in `settings.conf`.
3. Edit `site_inventory.ini`, `db_inventory.ini`, `settings.conf`.
4. `server_bootstrap.sh`
5. `site_provision.sh`
6. `ssh_db_bootstrap.sh` + `remote_ssh_connect_provision.sh` on each source + source `.my.cnf` for mysqldump.
7. `db_provision.sh`
8. `deploy.sh`

For details and edge cases, see `deploy/README.md`.
