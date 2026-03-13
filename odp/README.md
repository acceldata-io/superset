# ODP Superset Build

Build a self-contained Apache Superset tarball from local source code.

## Files

| File | Purpose |
|---|---|
| `VERSION` | ODP version string (e.g. `1.0.0-SNAPSHOT`) |
| `install_prereqs.sh` | Idempotently installs Python 3.11, Node.js 20, and system libraries |
| `buildtarball-from-source.sh` | Compiles frontend + backend and produces a portable venv tarball |
| `requirements.txt` | *(optional)* Additional Python packages to include in the tarball |

## Supported Platforms

- RHEL / CentOS / Rocky / AlmaLinux 8, 9
- Ubuntu 20.04, 22.04

## Quick Start

```bash
cd odp/

# 1. Set your version
echo "1.0.0" > VERSION

# 2. Build (installs prereqs automatically — needs root/sudo)
sudo ./buildtarball-from-source.sh

# 3. Build with custom DB extras
sudo ./buildtarball-from-source.sh --extras "postgres,mysql,trino,hive"

# 4. Skip prereqs if already installed
./buildtarball-from-source.sh --skip-prereqs
```

## What the Build Does

1. **Installs prerequisites** — Python 3.11, Node.js 20, system dev libraries
2. **`npm ci`** — Clean install of frontend dependencies
3. **`npm run build`** — Webpack production build → `superset/static/assets/`
4. **`npm run build-translation`** — Compiles `.po` → `.json` for frontend i18n
5. **Creates Python venv** — Installs pinned `requirements/base.txt` + Superset from source
6. **Compiles backend translations** — `.po` → `.mo` via pybabel
7. **Packs tarball** — Uses `venv-pack` to create a relocatable `*.tar.gz`

## Output

```
superset_environment_6_0_0_1_0_0.tar.gz   # the tarball
superset_environment_6_0_0_1_0_0_filelist.txt  # file listing for diffing
```

## Adding Custom Dependencies

Create `odp/requirements.txt` with any additional Python packages:

```
PyMySQL>=1.1.0
trino>=0.328.0
pyhive[hive]>=0.7.0
```

These are installed into the venv before packing.
