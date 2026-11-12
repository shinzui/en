#!/usr/bin/env python3
"""Apply an optional child scaffold, then reuse git-init for Git/GitHub creation."""
import json
from pathlib import Path
import shlex
import subprocess
import sys


def run(args, cwd):
    result = subprocess.run(args, cwd=cwd)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {shlex.join(args)}\n'
                           f'Files in {cwd} are preserved. Reconcile the failure there; '
                           'repository creation refuses nonempty targets. No registration or remote rollback is implied.')


def main():
    invocation = Path.cwd()
    # Seihou writes the active application before command execution. Recipe-only
    # inputs live on that application, not in the legacy flat variable summary.
    manifest = json.loads((invocation / '.seihou/manifest.json').read_text())
    active = [app for app in manifest['applications']
              if app['appliedAt'] == manifest['generatedAt']
              and any(instance['name'] == 'repo-dir' for instance in app['instances'])]
    if len(active) != 1:
        raise ValueError('Cannot identify the current repo-dir application; rerun through Seihou.')
    application = active[0]
    instance = next(instance for instance in application['instances'] if instance['name'] == 'repo-dir')
    resolved = {**instance['resolvedVars'], **(application.get('recipeInputs') or {})}
    controls = {key: value for key, value in resolved.items()
                if key.startswith(('repo.', 'git.'))}
    name = controls['repo.name']
    if name in ('', '.', '..'):
        raise ValueError('repo.name must be a real folder name, not empty, . or ..')
    target = Path(controls['repo.parentDir']).expanduser() / name
    if target.is_symlink() or (target.exists() and (not target.is_dir() or any(target.iterdir()))):
        raise ValueError(f'{target} already exists and is not an empty directory')
    target = target.absolute()
    scaffold = controls.get('repo.scaffold')
    bindings = json.loads(controls.get('repo.scaffoldBindings', '{}'))
    if not isinstance(bindings, dict) or not all(isinstance(key, str) and isinstance(value, str)
                                                for key, value in bindings.items()):
        raise ValueError('repo.scaffoldBindings must be a JSON object mapping child inputs to outer input names')
    variables = {key: value for key, value in resolved.items() if not key.startswith(('repo.', 'git.'))}
    for child_input, outer_input in bindings.items():
        if child_input not in variables:
            variables[child_input] = resolved[outer_input]
    # Ordinary dependencies would apply git-init/scaffold in the invocation
    # directory. Acquire their complete closures before applying them in target.
    install = ['seihou', 'install', controls['repo.source'], '--module', 'git-init']
    if scaffold:
        install += ['--module', scaffold]
    run(install, invocation)
    target.mkdir(parents=True, exist_ok=True)
    if scaffold:
        args = ['seihou', 'run', scaffold, '--no-save-prompted']
        for key, value in variables.items():
            args += ['--var', f'{key}={value}']
        run(args, target)
    variables = {key: value for key, value in controls.items() if key.startswith('git.') and value}
    variables.update({'git.initialCommit': 'true', 'git.createGithub': 'true', 'git.repoName': name})
    args = ['seihou', 'run', 'git-init', '--no-save-prompted']
    for key, value in variables.items():
        args += ['--var', f'{key}={value}']
    run(args, target)
    print(f'Created {target} -> https://github.com/{controls["git.githubOwner"]}/{name}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(f'repo-dir: {error}', file=sys.stderr)
        sys.exit(1)
