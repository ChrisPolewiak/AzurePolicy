# Configuration

Preferred location for local runtime configuration files.

## deployment-config.json

Place your local deployment config at:

- `configuration/deployment-config.json`

The file contains environment-specific values and should remain ignored by git.

## ado-env.yml

Place your ADO environment variables at:

- `configuration/ado-env.yml`

Copy `configuration/ado-env.example.yml` to `configuration/ado-env.yml` and fill in your values.
The file is in `.gitignore` — it stays local to your ADO repository and is never synced to GitHub.

| Variable | Description |
| --- | --- |
| `devopsManagedPool` | ADO agent pool name used by all pipelines |
| `serviceConnectionName` | Azure DevOps service connection name for `AzureCLI@2` tasks |
