# This file is dual licensed under the terms of the Apache License, Version
# 2.0, and the BSD License. See the LICENSE file in the root of this repository
# for complete details.

import getpass
import io
import os
import subprocess
import time
import typing
import zipfile

import click
import requests


def run(*args: str) -> None:
    print(f"[running] {list(args)}")
    subprocess.check_call(list(args))


def wait_for_build_complete_github_actions(
    session: requests.Session, token: str, run_url: str
) -> None:
    while True:
        response = session.get(
            run_url,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"token {token}",
            },
        )
        response.raise_for_status()
        if response.json()["conclusion"] is not None:
            break
        time.sleep(3)


def download_artifacts_github_actions(
    session: requests.Session, token: str, run_url: str
) -> typing.List[str]:
    response = session.get(
        run_url,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"token {token}",
        },
    )
    response.raise_for_status()

    response = session.get(
        response.json()["artifacts_url"],
        headers={
            "Content-Type": "application/json",
            "Authorization": f"token {token}",
        },
    )
    response.raise_for_status()
    paths = []
    for artifact in response.json()["artifacts"]:
        response = session.get(
            artifact["archive_download_url"],
            headers={
                "Content-Type": "application/json",
                "Authorization": f"token {token}",
            },
        )
        with zipfile.ZipFile(io.BytesIO(response.content)) as z:
            for name in z.namelist():
                if not name.endswith(".whl") and not name.endswith(".tar.gz"):
                    continue
                p = z.open(name)
                out_path = os.path.join(
                    os.path.dirname(__file__),
                    "dist",
                    os.path.basename(name),
                )
                with open(out_path, "wb") as f:
                    f.write(p.read())
                paths.append(out_path)
    return paths


def fetch_github_actions_artifacts(
    token: str, version: str
) -> typing.List[str]:
    session = requests.Session()

    workflow_runs = []

    # There is a race condition where no workflow run has triggered after
    # pushing the tag, so loop until we get the run.
    while True:
        response = session.get(
            (
                f"https://api.github.com/repos/pyca/cryptography/actions"
                f"/workflows/wheel-builder.yml/runs?event=push&"
                f"branch={version}"
            ),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"token {token}",
            },
        )
        response.raise_for_status()
        workflow_runs = response.json()["workflow_runs"]
        if len(workflow_runs) > 0:
            break
        time.sleep(3)

    run_url: str = workflow_runs[0]["url"]
    wait_for_build_complete_github_actions(session, token, run_url)
    return download_artifacts_github_actions(session, token, run_url)


@click.command()
@click.argument("version")
def release(version: str) -> None:
    """
    ``version`` should be a string like '0.4' or '1.0'.
    """
    print(
        f"Create a new GH PAT with only actions permissions at: "
        f"https://github.com/settings/tokens/new?"
        f"description={version}&scopes=repo"
    )
    github_token = getpass.getpass("Github person access token: ")

    # Tag and push the tag (this will trigger the wheel builder in Actions)
    run("git", "tag", "-s", version, "-m", f"{version} release")
    run("git", "push", "--tags")

    os.makedirs(os.path.join(os.path.dirname(__file__), "dist"), exist_ok=True)

    # Wait for Actions to complete and download the wheels
    github_actions_artifact_paths = fetch_github_actions_artifacts(
        github_token, version
    )

    # Upload wheels and sdist
    run("twine", "upload", *github_actions_artifact_paths)


if __name__ == "__main__":
    release()
