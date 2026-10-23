# Azure Policy by Code

This repository deploys Azure Policy definitions and assignments using a Policy as Code model aligned with the Azure Landing Zone (ALZ / Enterprise Scale) approach.

Policy definitions and initiatives are sourced from [Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) by Microsoft (MIT License). Custom definitions and assignments are managed in `source/own/` and `configuration/`.

---

## Start here

**[Przewodnik operatora (PL)](docs/README.pl.md)** · **[Operator guide (EN)](docs/README.md)**

The normal workflow is:

**Excel → TSV → B: build → C: definitions (if changed) → D: what-if → deploy**

Run **A** when you need a new Microsoft ALZ snapshot. Use **E** for cleanup and **F**
to update the framework. Cleanup and framework sync start in preview mode.

GitHub contains the reusable framework; environment data and deployment runs belong
in your Azure DevOps repository. Never publish environment-specific configuration by accident.

## Details when you need them

| Document | Description |
| --- | --- |
| [docs/REFERENCE.md](docs/REFERENCE.md) | Technical reference — file formats, scripts, Bicep/ARM structure, configuration (EN) |
| [docs/REFERENCE.pl.md](docs/REFERENCE.pl.md) | Dokumentacja techniczna — formaty plików, skrypty, Bicep/ARM, konfiguracja (PL) |
| [configuration/TSV-FORMAT.md](configuration/TSV-FORMAT.md) | Assignment and parameter table columns |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Changelog |

---

## Repository structure

```text
.
├── bicep/              # Bicep modules + AUTO-GENERATED ARM JSON (in .gitignore, passed via artifact)
├── configuration/      # Source of truth: Excel, TSV exports, deployment config
├── docs/               # Documentation
├── generated/          # AUTO-GENERATED config JSON (in .gitignore, passed via artifact)
├── .pipelines/         # Azure DevOps pipeline definitions (YAML)
├── scripts/            # Bash scripts (fetch, generate, deploy, cleanup)
└── source/
    ├── EnterpriseALZ/  # Snapshot from GitHub Azure/Enterprise-Scale (in .gitignore, passed via artifact)
    └── own/            # Custom policy definitions and initiatives
```

---

## License

[MIT License](LICENSE). Policy definitions sourced from [Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) by Microsoft (MIT License).