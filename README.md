# Azure Policy by Code

This repository deploys Azure Policy definitions and assignments using a Policy as Code model aligned with the Azure Landing Zone (ALZ / Enterprise Scale) approach.

Policy definitions and initiatives are sourced from [Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) by Microsoft (MIT License). Custom definitions and assignments are managed in `source/own/` and `configuration/`.

---

## Documentation

| Document | Description |
| --- | --- |
| [docs/README.md](docs/README.md) | Operator guide — ADO setup, pipelines A–F, step-by-step workflows (EN) |
| [docs/README.pl.md](docs/README.pl.md) | Przewodnik operatora — konfiguracja ADO, pipeline'y A–F, instrukcje krok po kroku (PL) |
| [docs/REFERENCE.md](docs/REFERENCE.md) | Technical reference — file formats, scripts, Bicep/ARM structure, configuration (EN) |
| [docs/REFERENCE.pl.md](docs/REFERENCE.pl.md) | Dokumentacja techniczna — formaty plików, skrypty, Bicep/ARM, konfiguracja (PL) |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Changelog |

---

## Repository structure

```text
.
├── bicep/              # Bicep modules + AUTO-GENERATED ARM JSON (in .gitignore, passed via artifact)
├── configuration/      # Source of truth: Excel, TSV exports, deployment config
├── docs/               # Documentation
├── generated/          # AUTO-GENERATED config JSON (in .gitignore, passed via artifact)
├── pipelines/          # Azure DevOps pipeline definitions (YAML)
├── scripts/            # Bash scripts (fetch, generate, deploy, cleanup)
└── source/
    ├── EnterpriseALZ/  # Snapshot from GitHub Azure/Enterprise-Scale (in .gitignore, passed via artifact)
    └── own/            # Custom policy definitions and initiatives
```

---

## License

[MIT License](LICENSE). Policy definitions sourced from [Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) by Microsoft (MIT License).