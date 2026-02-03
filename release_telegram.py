import json
import os
from pathlib import Path

import requests


def main() -> int:
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    chat_id = os.getenv("TELEGRAM_CHAT_ID")
    if not token or not chat_id:
        print("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID, skipping.")
        return 0

    api_base = os.getenv("TELEGRAM_API_BASE", "http://localhost:8081").rstrip("/")
    media_url = f"{api_base}/bot{token}/sendMediaGroup"

    repo = os.getenv("GITHUB_REPOSITORY", "")
    run_id = os.getenv("GITHUB_RUN_ID", "")
    version = os.getenv("VERSION") or os.getenv("GITHUB_REF_NAME", "").lstrip("v")
    is_prerelease = os.getenv("IS_PRERELEASE", "false").lower() == "true"

    lines = []
    if version:
        lines.append(f"FluxDO {'Pre-release' if is_prerelease else 'Release'} v{version}")

    if repo and version and not is_prerelease:
        lines.append(f"https://github.com/{repo}/releases/tag/v{version}")
    elif repo and run_id:
        lines.append(f"https://github.com/{repo}/actions/runs/{run_id}")

    release_notes = Path("release_notes.md")
    if release_notes.exists():
        content = release_notes.read_text(encoding="utf-8").strip()
        if content:
            lines.append("")
            lines.append(content)

    text = "\n".join(lines).strip()
    if not text:
        print("No message content, skipping.")
        return 0

    artifacts_dir = Path("dist")
    package_files = []
    if artifacts_dir.exists():
        package_files = sorted(
            p for p in artifacts_dir.iterdir() if p.is_file() and p.suffix in {".apk", ".ipa"}
        )

    if not package_files:
        print("No APK/IPA files found in dist/, skipping.")
        return 0

    media = []
    files = {}
    for idx, file_path in enumerate(package_files, start=1):
        key = f"file{idx}"
        media.append(
            {
                "type": "document",
                "media": f"attach://{key}",
            }
        )
        files[key] = file_path.open("rb")

    media[-1]["caption"] = text
    media[-1]["parse_mode"] = "Markdown"

    response = requests.post(
        media_url,
        data={
            "chat_id": chat_id,
            "media": json.dumps(media),
        },
        files=files,
        timeout=60,
    )
    for f in files.values():
        f.close()

    try:
        payload = response.json()
    except ValueError:
        payload = {"ok": False, "error": response.text}

    print("Response JSON:", payload)
    response.raise_for_status()
    if not payload.get("ok", False):
        raise RuntimeError(f"Telegram API error: {payload}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
