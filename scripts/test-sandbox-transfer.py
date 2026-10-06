#!/usr/bin/env python3
"""Exercise signed app processes, real file panels and sandbox persistence.

Requires a logged-in macOS desktop and Accessibility permission for the invoking terminal.
No real Backpocket bundle, store, preferences or clipboard is used.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
SOURCE_ID = "dev.m2na.backpocket.transfer-source"
TARGET_ID = "dev.m2na.backpocket.transfer-sandbox"
UI_HELPER = ROOT / "build/sandbox-transfer-ui"
UI_LOG = None


def command(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def require(condition, message):
    if not condition:
        raise AssertionError(message)

def bundle(binary_app, destination, identifier, sandbox, mas_binary=None):
    shutil.copytree(binary_app, destination, symlinks=True)
    info_path = destination / "Contents/Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    info["CFBundleIdentifier"] = identifier
    info["CFBundleName"] = "Backpocket Transfer Test"
    info["LSUIElement"] = False
    info["SUEnableAutomaticChecks"] = False
    if sandbox:
        shutil.rmtree(destination / "Contents/Frameworks", ignore_errors=True)
        shutil.copy2(mas_binary, destination / "Contents/MacOS/Backpocket")
        for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks"):
            info.pop(key, None)
    with info_path.open("wb") as target:
        plistlib.dump(info, target)
    args = ["codesign", "--force", "--sign", "-"]
    if sandbox:
        args += ["--entitlements", str(ROOT / "Resources/Backpocket.entitlements")]
    command(*args, str(destination), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    command("codesign", "--verify", "--deep", "--strict", str(destination))
    if sandbox:
        signed = command(
            "codesign", "-d", "--entitlements", ":-", str(destination), capture_output=True,
        )
        entitlements = plistlib.loads(signed.stdout.encode())
        require(entitlements.get("com.apple.security.app-sandbox") is True,
                "The target signature does not enable App Sandbox")
        require(entitlements.get("com.apple.security.files.user-selected.read-write") is True,
                "The target signature cannot read/write user-chosen files")


def report_directory(identifier, run, sandbox):
    home = Path.home()
    if sandbox:
        home = home / "Library/Containers" / identifier / "Data"
    return home / "Library/Application Support/BackpocketTransferProbe" / run


def stop_test_app(app):
    # `open` can exit before the app. Cleanup must not depend on the
    # launcher's state, and only this exact test bundle may be stopped.
    binary = str(app / "Contents/MacOS/Backpocket")
    rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    for row in rows.splitlines():
        pid, _, command_line = row.strip().partition(" ")
        command_line = command_line.strip()
        if command_line == binary or command_line.startswith(binary + " "):
            try:
                os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


def launch(app, identifier, run, stage, external=None, pick=None, saving=False, cancel=False):
    sandbox = identifier == TARGET_ID
    report_path = report_directory(identifier, run, sandbox) / f"{stage}.json"
    args = ["open", "-n", "-W", str(app), "--args",
            f"--transfer-probe={stage}", f"--transfer-run={run}",
            "-AppleLanguages", "(en)"]
    if not external and cancel:
        external = app.parent / "Backpocket-notes.json"
    if not external and pick is not None:
        external = pick / "Backpocket-notes.json" if saving else pick
    if external:
        args.append(f"--transfer-file={external}")
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 45
        if pick is not None or cancel:
            action = "cancel" if cancel else "save" if saving else "open"
            helper_args = [str(UI_HELPER), identifier, str(app), action]
            if action == "open":
                helper_args.append(pick.name)
            selected = subprocess.run(helper_args, capture_output=True, text=True, timeout=25)
            with UI_LOG.open("a") as log:
                log.write(json.dumps({"stage": stage, "action": action,
                                      "returncode": selected.returncode,
                                      "stdout": selected.stdout.strip(),
                                      "stderr": selected.stderr.strip()}) + "\n")
            # AXPress can close the app before the remote call returns.
            # A completed report plus the assertions below prove its effect.
            require(selected.returncode == 0 or report_path.exists(),
                    f"{stage}: {selected.stderr.strip()}")
        while not report_path.exists():
            require(time.monotonic() < deadline, f"{stage}: no report at {report_path}")
            require(process.poll() is None, f"{stage}: app exited without a report")
            time.sleep(0.25)
        process.wait(timeout=10)
        report = json.loads(report_path.read_text())
        require(report.get("ok") is True, f"{stage}: {report}")
        print(f"Verified app stage: {stage}", flush=True)
        return report
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        stop_test_app(app)


def check_launch_guard(app, identifier, run):
    # Capture and a throwaway path are defense in depth: if the guard ever
    # regresses, the DEBUG app still cannot watch the user's clipboard or
    # access their ordinary store. A normal startup would stay alive and
    # create this store, so either effect fails the assertion.
    unexpected_store = report_directory(identifier, run, identifier == TARGET_ID) / "Unexpected.store"
    process = subprocess.Popen(
        ["open", "-n", "-W", str(app), "--args", "--capture", f"--store={unexpected_store}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        require(process.wait(timeout=10) == 0, "Test bundle failed to exit without probe flags")
        require(not unexpected_store.exists(), "Test bundle reached normal storage initialization")
        return {"stage": "launch-guard", "bundleID": identifier, "ok": True}
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        stop_test_app(app)


def snapshot(report):
    return sorted(report["snapshot"]["notes"], key=lambda n: json.dumps(n, sort_keys=True))


def main():
    global SOURCE_ID, TARGET_ID, UI_LOG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="reuse existing debug binaries")
    parser.add_argument("--prepare-only", action="store_true", help="assemble isolated test bundles")
    options = parser.parse_args()
    run = str(uuid.uuid4()).upper()
    # LaunchServices may resolve a reused identifier to an older test bundle.
    # Each run gets new identities so UI actions cannot revive an old app.
    SOURCE_ID = f"dev.m2na.backpocket.transfer-source.{run.lower()}"
    TARGET_ID = f"dev.m2na.backpocket.transfer-sandbox.{run.lower()}"
    work = ROOT / "build/sandbox-transfer" / run
    work.mkdir(parents=True)
    UI_LOG = work / "ui-actions.jsonl"
    command("swiftc", str(ROOT / "scripts/sandbox-transfer-ui.swift"), "-o", str(UI_HELPER))
    if not options.skip_build:
        with (work / "build.log").open("w") as log:
            command(str(ROOT / "build.sh"), "debug", cwd=ROOT, stdout=log, stderr=log)
            command("env", "BACKPOCKET_MAS=1", "swift", "build", "--scratch-path", ".build/mas",
                    cwd=ROOT, stdout=log, stderr=log)
    binary_dir = command("env", "BACKPOCKET_MAS=1", "swift", "build", "--scratch-path",
                         ".build/mas", "--show-bin-path", cwd=ROOT, capture_output=True).stdout.strip()
    # Release builds ignore the probe flags. Never launch one here: the
    # unsandboxed source would then open the user's normal store instead.
    for binary in (ROOT / "build/Backpocket.app/Contents/MacOS/Backpocket",
                   Path(binary_dir) / "Backpocket"):
        require(b"BackpocketTransferProbe/" in binary.read_bytes(),
                f"{binary} has no DEBUG probe; rerun without --skip-build")
    source_app, target_app = work / "Source.app", work / "Sandbox.app"
    bundle(ROOT / "build/Backpocket.app", source_app, SOURCE_ID, False)
    bundle(ROOT / "build/Backpocket.app", target_app, TARGET_ID, True,
           Path(binary_dir) / "Backpocket")
    metadata = {"run": run, "work": str(work), "source": str(source_app), "target": str(target_app)}
    (work / "run.json").write_text(json.dumps(metadata, indent=2))
    print(json.dumps(metadata), flush=True)
    if options.prepare_only:
        return
    results = []
    archive = work / "Backpocket-notes.json"
    source = launch(source_app, SOURCE_ID, run, "export", pick=work, saving=True)
    require(source.get("hasUpdater") is True, "Source is not the direct-download variant")
    require(source.get("exported") is True and archive.exists(), "Source export failed")
    archive_bytes = archive.read_bytes()
    results.append(source)
    imported = launch(target_app, TARGET_ID, run, "import", external=archive, pick=archive)
    require(imported.get("hasUpdater") is False, "Target is not the App Store variant")
    require(f"/Library/Containers/{TARGET_ID}/Data" in imported["home"], "Target has no sandbox home")
    require(imported.get("externalReadDenied") is True, "External file was readable before selection")
    require((imported.get("imported"), imported.get("skipped")) == (3, 0), "Import counts differ")
    transferred = [n for n in snapshot(imported) if n["content"] != "already in the App Store version"]
    require(transferred == snapshot(source), "Imported text, dates, pins or duplicate notes differ")
    results.append(imported)
    for stage in ("reopen", "repeat", "invalid", "cancel", "export-sandbox"):
        corrupt = work / "invalid.json"
        corrupt.write_text('{"formatVersion":1,"notes":[')
        pick = {"repeat": archive, "invalid": corrupt, "export-sandbox": work}.get(stage)
        if stage == "export-sandbox":
            # Keep the original export intact; use a different destination directory.
            pick = work / "sandbox-export"
            pick.mkdir()
        result = launch(target_app, TARGET_ID, run, stage, pick=pick,
                        saving=stage == "export-sandbox", cancel=stage == "cancel")
        require(snapshot(result) == snapshot(imported), f"{stage}: persisted notes changed")
        if stage == "repeat":
            require((result.get("imported"), result.get("skipped")) == (0, 3), "Repeat added duplicates")
        if stage == "invalid":
            require(result.get("invalidFileRejected") is True, "Malformed file was not rejected")
        if stage == "cancel":
            require(result.get("cancelled") is True, "Cancelling the picker did not cancel import")
        if stage == "export-sandbox":
            require(result.get("exported") is True, "Sandbox export failed")
            exported = json.loads((pick / "Backpocket-notes.json").read_text())
            require(sorted(exported["notes"], key=lambda n: json.dumps(n, sort_keys=True))
                    == snapshot(imported), "Sandbox export did not preserve every note")
        results.append(result)
    original = launch(source_app, SOURCE_ID, run, "source-reopen")
    require(snapshot(original) == snapshot(source) and original["itemCount"] == 4,
            "Migration changed the original source data")
    require(archive.read_bytes() == archive_bytes, "Migration modified the original JSON")
    results.append(original)
    results.append(check_launch_guard(source_app, SOURCE_ID, run))
    results.append(check_launch_guard(target_app, TARGET_ID, run))
    (work / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"PASS: sandbox transfer, restart, repeat, invalid file, cancellation, export and source preservation\n{work / 'results.json'}")


def interrupted(signum, _frame):
    # Raising unwinds launch()'s finally block so an interrupted test cannot
    # leave its app alive and interfere with the user's normal shortcut.
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    main()
