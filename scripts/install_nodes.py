#!/usr/bin/env python3
"""Install custom nodes into a ComfyUI workspace.

Reads a JSON file with nodes that have a Comfy Registry ID and a git fallback.
Tries to install from the Comfy Registry via comfy-cli first, then falls back to
a git clone if the registry install fails.

Usage:
    python3 install_nodes.py <custom_nodes.json> <comfyui_dir>
"""

import json
import subprocess
import sys
from pathlib import Path


def run(cmd, cwd=None, check=False):
    """Run a shell command and return (returncode, stdout, stderr)."""
    result = subprocess.run(
        cmd,
        cwd=cwd,
        shell=True,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        print(f"Command failed: {cmd}")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        sys.exit(1)
    return result.returncode, result.stdout, result.stderr


def install_from_registry(comfyui_dir, registry_id, node_name):
    """Try to install a node from the Comfy Registry using comfy-cli."""
    print(f"[registry] {node_name}: trying comfy node registry-install {registry_id}")
    rc, out, err = run(
        f'comfy --workspace "{comfyui_dir}" --skip-prompt node registry-install {registry_id}',
        check=False,
    )
    if rc == 0:
        print(f"[registry] {node_name}: OK")
        return True
    print(f"[registry] {node_name}: registry-install failed, trying comfy node install")
    rc, out, err = run(
        f'comfy --workspace "{comfyui_dir}" --skip-prompt node install {registry_id}',
        check=False,
    )
    if rc == 0:
        print(f"[registry] {node_name}: OK")
        return True
    print(f"[registry] {node_name}: failed, will try git fallback")
    print(f"stderr: {err}")
    return False


def install_from_git(comfyui_dir, git_url, node_name):
    """Clone a node from git into the ComfyUI custom_nodes directory."""
    custom_nodes_dir = Path(comfyui_dir) / "custom_nodes" / node_name
    print(f"[git] {node_name}: cloning {git_url} -> {custom_nodes_dir}")
    custom_nodes_dir.parent.mkdir(parents=True, exist_ok=True)
    if custom_nodes_dir.exists():
        run(f'rm -rf "{custom_nodes_dir}"')
    rc, out, err = run(
        f'git clone --depth 1 "{git_url}" "{custom_nodes_dir}"',
        check=False,
    )
    if rc != 0:
        print(f"[git] {node_name}: failed")
        print(f"stderr: {err}")
        return False
    print(f"[git] {node_name}: OK")
    return True


def install_requirements(comfyui_dir, node_name):
    """Install the requirements.txt for a node if it exists."""
    req_file = Path(comfyui_dir) / "custom_nodes" / node_name / "requirements.txt"
    if not req_file.exists():
        return
    print(f"[deps] {node_name}: installing requirements.txt")
    rc, out, err = run(
        f'python3 -m pip install --no-cache-dir -r "{req_file}"',
        check=False,
    )
    if rc != 0:
        print(f"[deps] {node_name}: requirements install failed, continuing")
        print(f"stderr: {err}")
    else:
        print(f"[deps] {node_name}: OK")


def main(config_path, comfyui_dir):
    config_path = Path(config_path)
    comfyui_dir = Path(comfyui_dir)
    custom_nodes_dir = comfyui_dir / "custom_nodes"
    custom_nodes_dir.mkdir(parents=True, exist_ok=True)

    with open(config_path) as f:
        config = json.load(f)

    nodes = config["nodes"]

    # Install ComfyUI-Manager first so it is available for other installs.
    manager = next((n for n in nodes if n["name"] == "ComfyUI-Manager"), None)
    if manager:
        nodes = [manager] + [n for n in nodes if n["name"] != "ComfyUI-Manager"]

    for node in nodes:
        name = node["name"]
        registry_id = node.get("registry_id")
        git_url = node.get("git")

        installed = False
        if registry_id:
            installed = install_from_registry(comfyui_dir, registry_id, name)
        if not installed and git_url:
            installed = install_from_git(comfyui_dir, git_url, name)
        if not installed:
            print(f"[error] {name}: could not install from registry or git")
            sys.exit(1)

        install_requirements(comfyui_dir, name)

    print("All custom nodes installed.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <custom_nodes.json> <comfyui_dir>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
