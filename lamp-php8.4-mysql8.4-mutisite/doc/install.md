# Deployment install guide (step-by-step)

Target: **Ubuntu 24.04** (or similar) staging server. Run commands **as root** via `sudo` where shown.

**Repository layout (your case):**

- **Main Git repo:** [`zartashtech/scripts`](https://github.com/zartashtech/scripts) — this is the only thing you clone; it may contain many other folders beside the LAMP stack.
- **This project:** **`lamp-php8.4-mysql8.4-mutisite/`** is a **subfolder inside that repo** (path on GitHub: `scripts` → `lamp-php8.4-mysql8.4-mutisite/`). It is **not** the repository root.
- **On the server:** `git clone` creates a directory named `scripts` (same as the repo name). Always **`cd scripts/lamp-php8.4-mysql8.4-mutisite`** before running `deploy.sh`, `server_bootstrap.sh`, etc. Example project root: `/opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite`.

---

## 0. Clone the deployment project on the server

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

You need this full tree for `deploy/scripts/`, `deploy/config/`, and updates via `git pull`. A single downloaded script is not enough for Apache/PHP/MySQL provisioning or `deploy.sh`.

If you only copy files (no git remote), unpack so this folder contains `deploy/scripts/` and `deploy/config/`.

---

## 1. GitHub SSH access for the **private websites** repository

The **application** code lives in a **separate** GitHub repo (example: `zartashtech/monitoring_stack`). The server needs a deploy key (or other SSH auth) to `git fetch` that repo.

You can do this in either order: run `github_setup.sh` **before** section 0 (via `curl` below) or **after** you clone, from inside `lamp-php8.4-mysql8.4-mutisite`.

### Option A — Download only `github_setup.sh` (no clone yet)

Useful when you want SSH working first with minimal files. Raw URL must match where the script lives on the `main` branch:

- **As shipped in this repo layout:** under the LAMP folder:

```bash
curl -sSL https://raw.githubusercontent.com/zartashtech/scripts/main/lamp-php8.4-mysql8.4-mutisite/github_setup.sh -o github_setup.sh
sudo bash github_setup.sh zartashtech monitoring_stack
```

- **If you also keep a copy at the root of `scripts`**, you can use the shorter URL instead:

```bash
curl -sSL https://raw.githubusercontent.com/zartashtech/scripts/main/github_setup.sh -o github_setup.sh
sudo bash github_setup.sh zartashtech monitoring_stack
```

Replace `monitoring_stack` with the **private repo name** that holds your sites (the one `github_repo_ssh_url` in `settings.conf` will point at).

When the script prints the **public** key, add it in GitHub: **Repo → Settings → Deploy keys → Add deploy key** (read-only). Then continue the script when prompted so SSH is tested.

### Option B — From a full clone (same script)

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
sudo ./github_setup.sh zartashtech monitoring_stack
```

Use the same deploy-key step as in option A.

### `settings.conf`

Set `github_repo_ssh_url` to the SSH URL that matches what `github_setup.sh` configures (host alias or `git@github.com:...`).

Test (as root, if deploy runs as root), from the LAMP project root:

```bash
cd /opt/deploy/scripts/lamp-php8.4-mysql8.4-mutisite
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

1. (Optional) `curl` + `github_setup.sh` for the **private sites** repo, deploy key, finish the script — or do this after clone (section 1).
2. Clone `zartashtech/scripts` and `cd` into `lamp-php8.4-mysql8.4-mutisite`.
3. If you skipped step 1: run `github_setup.sh` here; set `github_repo_ssh_url` in `settings.conf`.
4. Edit `site_inventory.ini`, `db_inventory.ini`, `settings.conf` (if not already).
5. `server_bootstrap.sh`
6. `site_provision.sh`
7. `ssh_db_bootstrap.sh` + `remote_ssh_connect_provision.sh` on each source + source `.my.cnf` for mysqldump.
8. `db_provision.sh`
9. `deploy.sh`

For details and edge cases, see `deploy/README.md`.
