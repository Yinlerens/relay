import datetime
import json
import os
import subprocess


def main() -> None:
    ipa_path = "ios/build/Relay-unsigned.ipa"
    ipa_size = os.path.getsize(ipa_path)
    run_num = os.environ["GITHUB_RUN_NUMBER"]
    version = f"1.0.{run_num}"
    short_sha = os.environ["GITHUB_SHA"][:7]
    repo = os.environ["GITHUB_REPOSITORY"]
    base = f"https://github.com/{repo}/releases/download/latest"
    ipa_url = f"{base}/Relay-unsigned.ipa"
    icon_url = f"{base}/icon.png"

    commit_msg = subprocess.check_output(
        ["git", "log", "-1", "--pretty=%s"], text=True
    ).strip()
    build_date = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    desc = f"{commit_msg} ({short_sha})"

    source = {
        "name": "Relay",
        "identifier": "com.makima.relay.source",
        "subtitle": "Zero-telemetry multi-agent ACP control plane",
        "description": "Auto-updated unsigned iOS builds from GitHub Actions for SideStore / AltStore / Feather.",
        "iconURL": icon_url,
        "website": f"https://github.com/{repo}",
        "tintColor": "#6366F1",
        "featuredApps": ["com.makima.relay"],
        "apps": [
            {
                "name": "Relay",
                "bundleIdentifier": "com.makima.relay",
                "developerName": repo.split("/", 1)[0],
                "subtitle": "多 Agent 原生 iOS 客户端",
                "localizedDescription": "零遥测、自托管的多 Agent ACP 原生 SwiftUI 客户端，支持 Antigravity 与 CodeBuddy。",
                "iconURL": icon_url,
                "tintColor": "#6366F1",
                "version": version,
                "versionDate": build_date,
                "versionDescription": desc,
                "downloadURL": ipa_url,
                "size": ipa_size,
                "versions": [
                    {
                        "version": version,
                        "buildVersion": run_num,
                        "date": build_date,
                        "localizedDescription": desc,
                        "downloadURL": ipa_url,
                        "size": ipa_size,
                        "minOSVersion": "26.0",
                    }
                ],
            }
        ],
        "news": [],
    }

    with open("ios/build/source.json", "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(
        f"Generated ios/build/source.json: version={version} build={run_num} size={ipa_size}"
    )


if __name__ == "__main__":
    main()
