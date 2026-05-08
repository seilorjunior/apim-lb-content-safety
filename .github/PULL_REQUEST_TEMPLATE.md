## Summary

<!-- What does this PR change and why? Link any relevant issues. -->

## Checklist

- [ ] `az bicep build --file infra/main.bicep --stdout` passes
- [ ] `pytest` passes locally with coverage ≥ 80 %
- [ ] `ruff check .` is clean
- [ ] `bandit -c pyproject.toml -r function_app.py` is clean
- [ ] Updated README if behaviour or required env vars changed
- [ ] No secrets committed (verified `git diff` for keys / connection strings)
