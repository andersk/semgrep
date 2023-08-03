import click
import os
import re
import subprocess

from contextlib import contextmanager
from pathlib import Path
from textwrap import dedent

from semgrep.app import auth
from semgrep.commands.wrapper import handle_command_errors
from semgrep.util import abort
from semgrep.util import sub_check_output
from semgrep.verbose_logging import getLogger
from semgrep.error import SemgrepError

logger = getLogger(__name__)


@contextmanager
def working_dir(path: Path):
    """
    Sets the current working directory within the context
    """
    origin = Path().absolute()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(origin)

# Check if `gh` command is installed
# If not, install it.
def install_github_cli():
    # Avoiding circular imports
    from semgrep.error import SemgrepError

    gh_exists = False
    try:
        sub_check_output(
            ["command", "-v", "gh"],
            timeout=4,
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
        gh_exists = True
    except subprocess.CalledProcessError as e:
        if e.returncode == 1:
            # `gh` command not found
            pass
        else:
            raise e

    if gh_exists:
        return
    
    # NOTE: assume brew is already installed (for now)
    process = subprocess.Popen(
        ["brew", "install", "gh"],
        stdout=subprocess.PIPE, 
        stderr=subprocess.STDOUT,
        encoding="utf-8",
    )

    for line in process.stdout:
        logger.info(f"{line}")
    
    command = ["gh", "--version"]
    command_str = " ".join(command)

    try:
        sub_check_output(
            command,
            timeout=4,
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
    except subprocess.CalledProcessError as e:
        raise SemgrepError(dedent(
            f"""
            Command failed with exit code: {e.returncode}
            -----
            Command failed with output:
            {e.stderr}

            Failed to run '{command_str}'. Possible reasons:

            - the gh binary is not available

            Try installing gh with `brew install gh` or
            visit https://cli.github.com for more information with installation.
            """
        ).strip())
    
def github_cli_login():
    logged_in = False
    try:
        sub_check_output(
            ["gh", "auth", "status"],
            timeout=4,
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
        logged_in = True
    except subprocess.CalledProcessError as e:
        if e.returncode == 1:
            # e.g. `You are not logged into any GitHub hosts. Run gh auth login to authenticate.`
            pass
        else:
            raise e

    if logged_in:
        logger.debug(f"already logged in")
        return

    # NOTE: option to login via browser or token (for now, use browser)
    process = subprocess.Popen(
        ["gh", "auth", "login", "--web"],
        stdout=subprocess.PIPE, 
        stderr=subprocess.STDOUT,
        encoding="utf-8",
    )

    for line in process.stdout:
        logger.info(f"{line}")
    
    logger.info(f"done logging in")


def validate_github_repo(repo: str):
    """
    Ensure the repo path is a valid github repo
    """

    command = ["git", "-C", repo, "remote", "-v"]
    command_str = " ".join(command)
    try:
        sub_check_output(
            command,
            timeout=4,
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
    except subprocess.CalledProcessError as e:
        raise SemgrepError(dedent(
            f"""
            Command failed with exit code: {e.returncode}
            -----
            Command failed with output:
            {e.stderr}

            Failed to run '{command_str}'. Possible reasons:

            - the directory does not exist
            - the directory is not a git repository (or is not initialized)

            Try running `git init` in the directory of interest.
            """
        ).strip())

def get_default_branch_slow():
    fallback = "main"
    remote_name = "origin"
    command = ["git", "remote", "show", remote_name]
    command_str = " ".join(command)
    try:
        out = sub_check_output(
            command,
            timeout=60,  # NOTE: this can be very slow for large repos
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
    except subprocess.CalledProcessError as e:
        logger.debug(dedent(
            f"""
            Command failed with exit code: {e.returncode}
            -----
            Command failed with output:
            {e.stdout}

            Failed to run '{command_str}'. Possible reasons:

            - no remote named {remote_name} exists

            Try running `git remote add origin URL` with the URL of upstream repo.

            Falling back to '{fallback}' as the default branch.
            """
        ).strip())
        return fallback
    target_line = re.search("HEAD branch: (.*)", out, re.MULTILINE)
    if target_line:
        return target_line.group(1)
    logger.warning("Failed to parse default branch from git remote show output. Falling back to 'main'.")
    return fallback

def get_default_branch():
    """
    Get the default branch of the repo based on the remote ref.
    NOTE: We assume "origin" is the main remote name.
    """
    remote_name = "origin"
    prefix = f"refs/remotes/{remote_name}"

    command = ["git", "symbolic-ref", f"{prefix}/HEAD"]
    command_str = " ".join(command)

    out = "refs/remotes/origin/develop"  # ex. non-standard default branch
    try:
        out = sub_check_output(
            command,
            timeout=4,
            encoding="utf-8",
            stderr=subprocess.STDOUT,
        ).rstrip()
    except subprocess.CalledProcessError as e:
        logger.debug(dedent(
            f"""
            Command failed with exit code: {e.returncode}
            -----
            Command failed with output:
            {e.stdout}

            Failed to run '{command_str}'.

            Falling back to slow lookup method.
            """
        ).strip())
        return get_default_branch_slow()
    branch = out[len(prefix) + 1 :]
    return branch

def write_workflow_file(repo_path: str):
    """
    Write the workflow file to the repo.
    """
    validate_github_repo(repo_path)

    with working_dir(os.path.expanduser(repo_path)):
        branch = get_default_branch()

    logger.info(f"Using default branch: '{branch}'")

    text = dedent(f"""
            name: Semgrep
            on:
                workflow_dispatch: {{}}
                pull_request: {{}}
                push:
                    branches:
                        - {branch}
            jobs:
                semgrep:
                    name: semgrep/ci
                    runs-on: ubuntu-latest
                    if: (github.actor != 'dependabot[bot]')  
                    env:
                        SEMGREP_APP_TOKEN: ${{{{ secrets.SEMGREP_APP_TOKEN }}}}
                    container:
                        image: returntocorp/semgrep
                    steps:
                        - uses: actions/checkout@v3
                        - run: semgrep ci
            """
    ).strip()

    with working_dir(os.path.expanduser(repo_path)):
        if os.path.exists(".github/workflows/semgrep.yml"):
            logger.info("Semgrep CI already installed")
            return
        os.makedirs(".github/workflows", exist_ok=True)
        with open(".github/workflows/semgrep.yml", "w") as f:
            f.write(text)

def set_workflow_secret(repo_path: str, login_token: str):
    """
    Set the workflow secret in the repo.
    """
    list_command = ["gh", "secret", "list", "-a", "actions"]
    with working_dir(os.path.expanduser(repo_path)):
        out = sub_check_output(
                list_command,
                timeout=4,
                encoding="utf-8",
                stderr=subprocess.STDOUT,
            ).rstrip()
        logger.info(f"secret list out: {out}")

        if "SEMGREP_APP_TOKEN" in out:
            logger.info("Semgrep CI secret already set")
            return

        set_command = ["gh", "secret", "set", "SEMGREP_APP_TOKEN", "-a", "actions", "--body", login_token]
        out = sub_check_output(
                set_command,
                timeout=4,
                encoding="utf-8",
                stderr=subprocess.STDOUT,
        ).rstrip()
        logger.info(f"secret set out: {out}")

def instruct_git_push():
    logger.info(f"Within the repo, run `git add . && git commit -m 'add semgrep' && git push` to push the workflow file to Github.")

def verify_workflow_added(repo_path: str):
    """
    Verify the workflow was added to the repo.
    """
    list_command = ["gh", "workflow", "list", "-a"]
    with working_dir(os.path.expanduser(repo_path)):
        out = sub_check_output(
                list_command,
                timeout=4,
                encoding="utf-8",
                stderr=subprocess.STDOUT,
            ).rstrip()
        # logger.info(f"secret list out: {out}")
        # TODO: check for active vs inactive workflows
        if "Semgrep" in out:
            return True
    return False

@click.command()
@click.argument("repo_path", nargs=1, type=click.Path(allow_dash=True))
@handle_command_errors
def install_semgrep_ci(repo_path: str) -> None:
    """
    Install Semgrep CI in Github Actions for a specific local repository.

    Must be logged in to use; see `semgrep login`

    Visit https://semgrep.dev/install_semgrep_ci for more information
    """
    login_token = auth._read_token_from_settings_file()
    if not login_token:
        abort(
            "You must be logged in to install Semgrep CI. Please run `semgrep login` first."
        )
    logger.info("Installing Semgrep CI...")
    install_github_cli()    
    github_cli_login()
    workflow_added = verify_workflow_added(repo_path)
    if workflow_added:
        logger.info("Semgrep CI workflow already added")
        return
    write_workflow_file(repo_path)
    set_workflow_secret(repo_path, login_token)
    instruct_git_push()
    # NOTE: `gh workflow list -a` should now show the `Semgrep` workflow
    logger.info("Done installing Semgrep CI.")
