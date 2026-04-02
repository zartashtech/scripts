# bash multi-site deployment (ubuntu)

This folder contains a **bash-only, production-safe deployment system** for deploying **multiple websites** from **one private GitHub repo** (monorepo) to **separate live directories** on an Ubuntu server.

You maintain `deploy/config/site_inventory.ini`. Running the deploy script will:

- fetch/update the private repo locally (kept for future resync)
- deploy **only the websites listed with `active=yes`**
- sync **only the specified repo folder(s)** into each site’s docroot under `/home/<website_id>/`

No Ansible, no Docker, no Python.

**Step-by-step command list:** see [`doc/install.md`](../doc/install.md) in the project root.

**Upstream layout:** the **main** repository is **`zartashtech/scripts`**. This deployment stack is **only** the subfolder **`lamp-php8.4-mysql8.4-mutisite/`** inside it (not the repo root). Clone `scripts`, then open **`scripts/lamp-php8.4-mysql8.4-mutisite`** on disk so `deploy/` is your working directory when you run the scripts.

---

## folder structure

- `deploy/config/`
  - `settings.conf`: main configuration (repo url, paths, rsync options, safety flags)
  - `site_inventory.ini`: list of websites to deploy (ini style; section name = `website_id`)
  - `db_inventory.ini`: shared db setup + sources + mapping (recommended; optional `db_users=a,b,c` per database)
- `deploy/scripts/`
  - `deploy.sh`: main entrypoint (validates, optional inactive purge, syncs repo, deploys active sites)
  - `sync_repo.sh`: clones/fetches the repo into a fixed local path
  - `deploy_site.sh`: deploys one site (staging via `git archive`, then `rsync`)
  - `read_inventory.sh`: reads ini inventory into a safe tab format
  - `validate_inventory.sh`: validates the inventory (missing values, duplicates, etc.)
  - `helpers.sh`: shared helpers (logging, locks, dependency checks, safety checks)
  - `server_bootstrap.sh`: installs apache + php8.4-fpm + mysql8.4 (one-time)
  - `site_provision.sh`: creates vhosts + docroots + optional certbot (+ inactive purge if `purge_inactive=yes`)
  - `cleanup_inactive_sites.sh`: removes vhost + `/home/<website_id>` for all `active=no` rows when `purge_inactive=yes`
  - `db_provision.sh`: creates shared dbs/users + imports via ssh+mysqldump
  - `ssh_db_bootstrap.sh`: one staging key + ssh test all `[source:*]` from `db_inventory.ini`
  - `remote_ssh_connect_provision.sh`: run on each remote host to append a caller's **public** key to `authorized_keys`
  - `read_db_inventory.sh`: reads db inventory into a safe tab format
  - `validate_db_inventory.sh`: validates db inventory and mappings
- `deploy/logs/`: log files (created automatically)
- `deploy/tmp/`: temporary files and lock file (created automatically)

---

## prerequisites (ubuntu)

Install these packages:

```bash
sudo apt-get update
sudo apt-get install -y git rsync awk sed grep tar coreutils
```

You also need SSH access to your **private** GitHub repository.

---

## github ssh authentication (private repo)

Your deployment repo can be public, but your **website repo is private**, so the server must authenticate to GitHub.

### recommended: deploy key (read-only)

Your repository already includes a helper script `github_setup.sh` that:

- creates a deploy key
- prints the public key
- configures an SSH host alias like `github-<repo_name>`
- tests `git ls-remote` access

Run it on the server (as root):

```bash
sudo ./github_setup.sh <github_user_or_org> <private_repo_name>
```

Then in `deploy/config/settings.conf`, set:

- `github_repo_ssh_url` to the SSH url that matches your SSH config/alias

Example:

```bash
github_repo_ssh_url="git@github-myprivaterepo:myorg/myprivaterepo.git"
```

If you prefer not to use an alias, use:

```bash
github_repo_ssh_url="git@github.com:myorg/myprivaterepo.git"
```

---

## configure

Edit:

- `deploy/config/settings.conf`
- `deploy/config/site_inventory.ini`
- `deploy/config/db_inventory.ini` (shared databases)

### ssh access for database pulls (one key, sources from db_inventory only)

1. In `settings.conf`, **`ssh_db_identity_file`** points at a **single** private key on staging (default `/root/.ssh/db_pull_ed25519`). Leave empty only if you intentionally use the default ssh agent / `id_*` keys.
2. On **staging**, run:

```bash
sudo bash deploy/scripts/ssh_db_bootstrap.sh
```

It reads every **`[source:*]`** from `db_inventory.ini`, creates the key if missing, and tests `ssh` (BatchMode) to each host.
3. If any host fails, the script prints the **public key**. On **each source server**, copy `deploy/scripts/remote_ssh_connect_provision.sh` and run it as the same **`ssh_user`** as in `[source:*]` (often root):

```bash
sudo bash remote_ssh_connect_provision.sh
```

When prompted, choose that username (default `root`), then paste the **single-line public key**. Non-interactive example:

```bash
printf '%s\n' "$(cat /root/.ssh/db_pull_ed25519.pub)" | TARGET_USER=root sudo -E bash remote_ssh_connect_provision.sh
```

4. Re-run **`ssh_db_bootstrap.sh`** until all sources report **ssh ok**.
5. **`db_provision.sh`** uses **`ssh -i ssh_db_identity_file`** for all imports.

### db inventory: several mysql users, one database

In `[local_db:*]` you can use either:

- **`db_user=one_user`** (single account), or
- **`db_users=app_user,reporting_user,cron_user`** (comma-separated; no spaces, or trim spaces only).

All listed users get **`GRANT ALL` on that database** on staging (simple default). For stricter rights (read-only, etc.), adjust grants manually after provisioning or extend the scripts.

### site inventory rules

`deploy/config/site_inventory.ini` must:

- use one section per site: the **section name is the `website_id`** (e.g. `[site1]` means id `site1`)
- **do not** set `website_id=` or `live_directory=` inside the file; the home path is always computed as `/home/<website_id>`
- provide required keys per site: `domain`, `repo_folder`, `branch`, `active` (recommended order in the file: **active** first for quick scanning, then domain → repo_folder → branch → docroot_subdir → ssl → certbot_email)
- use `active=yes` to deploy, `active=no` to skip
- with **`purge_inactive=yes`** in `settings.conf`, each run of **`deploy.sh`** or **`site_provision.sh`** runs **`cleanup_inactive_sites.sh`**, which:
  - for **`active=no`**: removes **Let’s Encrypt** cert for that `domain` (best effort via `certbot delete`), **Apache** vhosts for that id (including common **`domain-le-ssl.conf`** / **`id-le-ssl.conf`** from certbot), and **`/home/<website_id>`**
  - for **orphan vhosts**: if `/etc/apache2/sites-available/<id>.conf` exists but `<id>` is **not listed anywhere** in `site_inventory.ini`, the same teardown runs (domain taken from `ServerName` in the vhost file)
  - **MySQL** is unchanged (shared `db_inventory.ini`). **`/home/ubuntu`** and similar are never scanned for deletion; only **`/home/<managed_id>`** tied to inventory or a matching managed vhost name is removed.
- sites with **`active=yes`** stay on the server and **`deploy.sh`** keeps **resyncing** their repo folder into **`/home/<website_id>/<docroot_subdir>`** as before.
- have **unique** section names (ids), **unique** `domain` values, and thus unique `/home/<id>` paths
- follow your naming convention: `repo_folder` must start with `website_id`
- optional `docroot_subdir` (default `public_html`): Apache `DocumentRoot` is `/home/<website_id>/<docroot_subdir>` (no per-site home path variable in the ini)

Tip: keep one website per top-level folder inside your private repo, e.g.:

- `site1-app/`
- `site2-portal/`
- `site3-blog/`

This system also validates that `repo_folder` **starts with** `website_id` (your requested convention).

---

## run deployment

From the repo root:

```bash
sudo bash deploy/scripts/deploy.sh
```

### deploy only one website_id

```bash
sudo bash deploy/scripts/deploy.sh --site site1
```

### use a different inventory file

```bash
sudo bash deploy/scripts/deploy.sh --inventory /path/to/site_inventory.ini
```

### verbose output

```bash
sudo bash deploy/scripts/deploy.sh --verbose
```

---

## dry run mode

In `deploy/config/settings.conf`:

```bash
dry_run="yes"
```

Dry run will:

- still validate inventory
- still fetch repo metadata (git fetch)
- **not** actually change live files (rsync uses `-n`)

---

## delete safety

By default, this system does **not delete** files from your live directories.

In `deploy/config/settings.conf`:

```bash
enable_delete="no"
```

If you set:

```bash
enable_delete="yes"
```

then `rsync --delete` is used for deployments. Only enable this if you fully understand the consequences.

---

## logs

Logs are written to:

- `deploy/logs/deploy-YYYYmmdd-HHMMSS.log` (one per run)

Each run includes:

- start/end markers
- inventory validation results
- repo sync results
- per-site deploy status

---

## troubleshooting

- **git auth fails**: run `github_setup.sh` again and re-test `git ls-remote` for your repo URL.
- **wrong branch**: verify the `branch` field in the inventory. This system deploys per-site using `git archive <branch> <repo_folder>`.
- **repo_folder missing**: confirm the folder exists at the top-level in the private repo, and matches the inventory.
- **permissions**: this system uses `rsync -a`. If you need ownership fixes, do that outside (or extend the scripts).
- **concurrent runs blocked**: a lock file is used. If a previous run crashed, remove the lock file from `deploy/tmp/` after verifying no deploy is running.

---

## step 1: bootstrap (one-time)

```bash
sudo bash deploy/scripts/server_bootstrap.sh
```

## step 2: provision sites (one-time per site, but safe to re-run)

```bash
sudo bash deploy/scripts/site_provision.sh
```

## step 2b: provision/import databases (safe to re-run)

```bash
sudo bash deploy/scripts/db_provision.sh
```

## step 3: deploy code (repeatable)

```bash
sudo bash deploy/scripts/deploy.sh
```

