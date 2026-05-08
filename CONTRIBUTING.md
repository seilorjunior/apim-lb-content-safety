# Contributing

Thanks for your interest! This is a small dev-sample template, so contributions
are welcome but the bar for new features is "does it make the load-balancing
story clearer or safer?".

## Dev setup

```pwsh
# Tooling
winget install Microsoft.AzureCLI
winget install Microsoft.AzureFunctionsCoreTools
winget install Microsoft.AzureDeveloperCLI
winget install Python.Python.3.11

# Python deps
cd src/api
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt -r requirements-dev.txt
```

## Quality gates

Before opening a PR:

```pwsh
# Bicep build (validates all modules)
az bicep build --file infra/main.bicep --stdout > $null

# Python tests + coverage
cd src/api
pytest --cov --cov-report=term-missing      # ≥ 80 % branch coverage
ruff check .
bandit -r . -ll -c pyproject.toml
```

## Commit style

[Conventional Commits](https://www.conventionalcommits.org/). Useful types:

- `feat:` user-visible change (new endpoint, new policy guard)
- `fix:` bug fix
- `docs:` README / mkdocs / inline docs
- `infra:` Bicep / azd hook changes
- `ci:` GitHub Actions
- `chore:` housekeeping

## Pull request checklist

- [ ] `azd provision --preview` succeeds locally with default + `AZURE_USE_EXTERNAL_CACHE=true`.
- [ ] `pytest --cov` passes ≥ 80 %.
- [ ] `bandit` is clean (no medium+ findings).
- [ ] README updated if a new env var, endpoint, or policy guard was introduced.
- [ ] If you added a Bicep resource, the linter passes with no `#disable-next-line` suppressions.
