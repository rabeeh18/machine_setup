# machine_setup

Everything this laptop needs, in one list, installed by one script.

## After a fresh Windows install

1. Open <https://github.com/rabeeh18/machine_setup> in a browser and sign in.
2. Click **Code → Download ZIP**, then unzip it anywhere, for example to `D:\machine_setup`.
3. Open PowerShell in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```

   It installs Git (with sign-in), the GitHub CLI and Claude, puts the portable tools in `D:\Dev`, sets your Git name and email, and offers to sign you in to GitHub in the browser. Windows may ask for permission (UAC) for some installers.
4. Clone your projects, for example `git clone https://github.com/rabeeh18/sadak.git D:\Projects\Fleet`. Each project's `HANDOFF.md` covers its own setup, such as databases and `.env.local` files.

Other options:

| Command | Does |
|---|---|
| `install.ps1 -DryRun` | Shows what it would do, changes nothing |
| `install.ps1 -Optional` | Also installs tools marked optional (VS Code) |
| `install.ps1 -Only sadak` | Only tools for one project, plus shared ones |
| `install.ps1 -SkipGitSetup` | Installs tools without touching Git settings |

Running it again is safe: anything already installed is skipped.

## Adding a tool

These rules apply to anyone editing this repo, including assistants working on other projects.

1. **Add one entry** to `tools` in `requirements.json`. Don't create a second list or a per-project file.
2. **Choose the type:**
   - `winget`: a normal Windows app. Find the id with `winget search <name>` and use the exact id, such as `Git.Git`.
   - `zip`: a portable tool unzipped into `D:\Dev\<folder>` (no admin, no PATH changes). Use `source` as one of:
     - `adoptium:<major>` for a Temurin JDK
     - `postgres:<major>` for PostgreSQL binaries
     - `url:<https link>`, ideally with a `"sha256"` field

     Set `to` (the target folder) and `check` (a file that proves it's installed).
3. **Set `for`** to the project names that need it, or `["all"]`. If a tool is already listed, add your project name to its `for` instead of adding a duplicate.
4. **Add `"optional": true`** for nice-to-haves.
5. **Add a `note`** for anything a future reader needs to know.
6. **Keep this file about installs only.** Project setup steps (databases, env files, seeds) belong in that project's own `HANDOFF.md`.
7. **Test before committing:** run `install.ps1 -DryRun` and check that your entry appears correctly.

### Entry examples

```json
{ "name": "Node.js LTS", "type": "winget", "id": "OpenJS.NodeJS.LTS", "for": ["some-project"] }
{ "name": "Temurin JDK 17", "type": "zip", "source": "adoptium:17", "to": "D:\\Dev\\jdk-17", "check": "bin\\java.exe", "for": ["other-project"] }
```

## Disk layout

| Path | Contents |
|---|---|
| `D:\Dev\` | Portable tools (JDKs, PostgreSQL, Maven cache at `D:\Dev\m2`) |
| `D:\Projects\` | Cloned project repos |
