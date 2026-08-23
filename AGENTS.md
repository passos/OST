# Repository Workflow

## Branch Policy

- Make all new changes on the `develop` branch.
- Push unreleased work only to `origin/develop`.
- Treat every push to `main` as a new version release.
- Do not push to `main` unless the user explicitly requests a release.
- Before changing code, switch to `develop` and update it from `origin/develop`.

## Release Policy

- Promote `develop` to `main` only as part of an explicitly requested version release.
- Run `script/test.sh` before pushing a release to `main`.
