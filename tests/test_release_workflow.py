"""The tag-triggered GitHub Release must give working instructions (docker.yml)."""

from pathlib import Path
import re
import shutil
import subprocess
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def _release_steps() -> list[dict[str, Any]]:
    workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "docker.yml").read_text(encoding="utf-8"))
    steps: list[dict[str, Any]] = workflow["jobs"]["release"]["steps"]
    return steps


def test_release_is_a_draft_without_the_source_less_bundle() -> None:
    """The zip held a compose file that builds from source it did not contain; publishing is manual."""
    steps = _release_steps()
    assert "Build deploy bundle" not in [s.get("name") for s in steps]
    create = next(s for s in steps if s.get("name") == "Create GitHub Release")
    assert create["with"]["draft"] is True
    assert "files" not in create["with"]


@pytest.mark.skipif(shutil.which("bash") is None or shutil.which("git") is None, reason="needs bash and git")
def test_release_notes_pull_lowercase_images_and_run_from_source(tmp_path: Path) -> None:
    """GHCR image names are lowercase; `docker pull ghcr.io/IPT-MMDA/...` is an invalid reference."""
    notes = next(s for s in _release_steps() if s.get("name") == "Generate release notes")
    script = notes["run"]
    for expr, value in {
        "${{ github.ref_name }}": "v0.5.0",
        "${{ github.repository }}": "IPT-MMDA/dt4lc",
        "${{ github.event.repository.name }}": "dt4lc",
        "${{ needs.prepare.outputs.version }}": "0.5.0",
    }.items():
        script = script.replace(expr, value)
    assert "${{" not in script
    output = tmp_path / "github_output"
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "BACKEND_REF": "ghcr.io/IPT-MMDA/dt4lc/backend:0.5.0",
        "FRONTEND_REF": "ghcr.io/IPT-MMDA/dt4lc/frontend:0.5.0",
        "GITHUB_OUTPUT": str(output),
    }
    subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, check=True, capture_output=True)
    text = output.read_text(encoding="utf-8")

    assert "docker pull ghcr.io/ipt-mmda/dt4lc/backend:0.5.0" in text
    assert "docker pull ghcr.io/ipt-mmda/dt4lc/frontend:0.5.0" in text
    assert "git clone --branch v0.5.0 https://github.com/IPT-MMDA/dt4lc.git" in text
    assert "docker compose --profile ollama up -d" in text
    assert "dt4lc-deploy" not in text


def test_dev_builds_publish_but_latest_stays_on_master() -> None:
    """dev.dt4lc.org runs the `dev` images, so pushes to dev build; `latest` must still mean master."""
    workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "docker.yml").read_text(encoding="utf-8"))
    on = workflow.get("on", workflow.get(True))  # YAML 1.1 reads the bare key `on` as true
    assert "dev" in on["push"]["branches"]
    check = next(s for s in workflow["jobs"]["prepare"]["steps"] if s.get("id") == "check")
    assert '"refs/heads/dev"' in check["run"]
    for job in ("backend", "frontend"):
        meta = next(s for s in workflow["jobs"][job]["steps"] if s.get("id") == "meta")
        latest = [line.strip() for line in meta["with"]["tags"].splitlines() if "value=latest" in line]
        assert latest == [
            "type=raw,value=latest,enable=${{ github.ref == 'refs/heads/master' || github.ref == 'refs/heads/main' }}"
        ], job


def test_startup_installs_the_deploy_program_unchanged() -> None:
    """startup.sh carries its own copy of ssh-deploy.sh: the release it checks out may predate the program."""
    startup = (ROOT / "deploy" / "gcp" / "startup.sh").read_text(encoding="utf-8")
    program = (ROOT / "deploy" / "gcp" / "ssh-deploy.sh").read_text(encoding="utf-8")
    copy = re.search(r"<<'PROGRAM'\n(.*?\n)PROGRAM\n", startup, flags=re.S)
    assert copy is not None
    assert copy.group(1) == program


def test_deploy_pins_the_ssh_host_key_and_keeps_the_iap_commands() -> None:
    """A host outside Google Cloud is reached over SSH only with its pinned key; Google hosts keep IAP."""
    workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "deploy.yml").read_text(encoding="utf-8"))
    steps = {step["name"]: step for step in workflow["jobs"]["app"]["steps"]}
    configure = steps["Configure the host from its environment"]["run"]
    assert "-o StrictHostKeyChecking=yes" in configure
    assert '-o UserKnownHostsFile="$RUNNER_TEMP/known_hosts"' in configure
    assert "accept-new" not in configure and "StrictHostKeyChecking=no" not in configure
    assert (
        '--command "sudo git -C /opt/dt4lc fetch -q --tags origin && sudo git -C /opt/dt4lc checkout -q --detach '
        "'${{ needs.target.outputs.checkout }}' && sudo /opt/dt4lc/deploy/gcp/configure.sh\""
    ) in configure
    assert (
        '--command "sudo /opt/dt4lc/deploy/gcp/update.sh '
        "'${{ needs.target.outputs.ref }}' '${{ needs.target.outputs.tag }}'\""
    ) in steps["Update the host"]["run"]
    for name in ("Authenticate to Google Cloud", "Set up gcloud", "Update the host"):
        assert steps[name]["if"] == "vars.DEPLOY_SSH_HOST == ''", name
