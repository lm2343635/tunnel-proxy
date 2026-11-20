"""Allocate and resume notarized TunnelProxy builds from release.sh."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from uuid import UUID


ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
RUNS = BUILD / "release-runs"
PROJECT = ROOT / "TunnelProxy.xcodeproj/project.pbxproj"
RELEASE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}")


def digest(path):
    sha256 = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha256.update(block)
    return sha256.hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stream.name, path)


def build_floor():
    configured = re.findall(r"\bCURRENT_PROJECT_VERSION\s*=\s*([0-9]+);", PROJECT.read_text())
    if not configured:
        raise ValueError("No numeric CURRENT_PROJECT_VERSION found in the Xcode project.")
    numbers = [int(value) for value in configured]
    numbers.extend(int(path.name) for path in RUNS.iterdir() if path.name.isdecimal())
    for path in BUILD.glob("TunnelProxy-*-build*.dmg"):
        match = re.search(r"-build([0-9]+)(?:-|\.dmg$)", path.name)
        if match:
            numbers.append(int(match[1]))
    for path in BUILD.glob("release.*/export/TunnelProxy.app/Contents/Info.plist"):
        with path.open("rb") as stream:
            build = str(plistlib.load(stream).get("CFBundleVersion", ""))
        if build.isdecimal():
            numbers.append(int(build))
    return max(numbers)


def source_metadata():
    return {
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"])),
    }


def release(args, lock_fd):
    def run(*command, **options):
        options.setdefault("check", True)
        return subprocess.run(command, pass_fds=(lock_fd,), **options)

    if args.version:
        build = build_floor() + 1
        directory = RUNS / str(build)
        with tempfile.TemporaryDirectory(dir=RUNS) as pending:
            reservation = Path(pending) / "reservation"
            reservation.mkdir()
            (reservation / "signed").mkdir()
            write_json(reservation / "release.json", {"version": args.version, "build": build})
            reservation.rename(directory)
    else:
        build = args.resume
        directory = RUNS / str(build)
        if not (directory / "release.json").is_file():
            raise ValueError(f"No saved release for Build {build}.")

    record_path = directory / "release.json"
    record = read_json(record_path)
    version = record["version"]
    filename = f"TunnelProxy-{version}-build{build}.dmg"
    signed = directory / "signed" / filename
    final = directory / filename
    print(f"TunnelProxy {version} (Build {build}) — {directory}", flush=True)

    if record.get("final_sha256"):
        if digest(final) != record["final_sha256"]:
            raise ValueError(f"The verified DMG has changed: {final}")
        report(final, record)
        return

    profile = os.environ.get("NOTARY_PROFILE") or record.get("notary_profile") or "TunnelProxyNotary"

    def notary(action, *arguments, **options):
        return run("xcrun", "notarytool", action, *arguments, "--keychain-profile", profile, **options)

    if not signed.exists():
        if record.get("signed_sha256"):
            raise ValueError(f"Restore the original signed DMG at {signed} before resuming.")
        record.update(source_metadata())
        write_json(record_path, record)
        run(
            "./release.sh",
            env=dict(
                os.environ,
                TP_RELEASE_VERSION=version,
                TP_RELEASE_BUILD=str(build),
                TP_RELEASE_OUTPUT=str(signed.parent),
            ),
        )

    signed_hash = digest(signed)
    if record.get("signed_sha256", signed_hash) != signed_hash:
        raise ValueError(f"The original signed DMG has changed: {signed}")
    record["signed_sha256"] = signed_hash
    write_json(record_path, record)

    response_path = directory / "submission.json"
    submission = record.get("submission_id")
    if not submission and response_path.exists():
        try:
            submission = str(UUID(read_json(response_path)["id"]))
        except (ValueError, KeyError, TypeError):
            pass  # The upload may have been interrupted before the response was written.

    if args.submission_id:
        if not record.get("submission_started_at"):
            raise ValueError("This build has no previous submission attempt.")
        if submission and submission != args.submission_id:
            raise ValueError(f"This build already has submission {submission}.")
        info = json.loads(notary("info", args.submission_id, "--output-format", "json", capture_output=True).stdout)
        if info.get("name") != filename:
            raise ValueError(f"Submission {args.submission_id} does not match {filename}.")
        submission = args.submission_id

    if not submission:
        if record.get("submission_started_at") and not args.retry_submit:
            raise ValueError(
                f"Upload outcome unknown for {filename} since {record['submission_started_at']}. "
                f"Check notarytool history with profile {profile}. "
                f"Resume Build {build} with --submission-id UUID, or use --retry-submit "
                "after confirming there is no previous submission."
            )
        notary("history", stdout=subprocess.DEVNULL)
        record["notary_profile"] = profile
        record["submission_started_at"] = datetime.now(timezone.utc).isoformat()
        write_json(record_path, record)
        with response_path.open("w") as response:
            notary("submit", str(signed), "--no-wait", "--output-format", "json", stdout=response)
        submission = str(UUID(read_json(response_path)["id"]))

    record["submission_id"] = submission
    write_json(record_path, record)
    print(f"Apple submission: {submission}", flush=True)

    status = record.get("notary_status")
    if status not in ("Accepted", "Invalid", "Rejected"):
        result = notary(
            "wait", submission, "--timeout", "30m", "--output-format", "json",
            stdout=subprocess.PIPE, text=True, check=False,
        )
        try:
            status = json.loads(result.stdout)["status"]
        except (ValueError, KeyError):
            result.check_returncode()
            raise
        record["notary_status"] = status
        write_json(record_path, record)

    if status not in ("Accepted", "Invalid", "Rejected"):
        raise ValueError(f"Apple status is {status}. Resume Build {build} to wait again.")
    notary_log = directory / "notary-log.json"
    if not notary_log.exists():
        notary("log", submission, str(notary_log.with_suffix(".tmp")))
        notary_log.with_suffix(".tmp").replace(notary_log)
    if status != "Accepted":
        raise ValueError(f"Apple status is {status}. See {notary_log}.")

    # Keep the exact bytes sent to Apple so stapling can always be retried.
    with tempfile.TemporaryDirectory(dir=directory) as staging:
        stapled = Path(staging) / filename
        shutil.copyfile(signed, stapled)
        run("xcrun", "stapler", "staple", str(stapled))
        run("xcrun", "stapler", "validate", str(stapled))
        run("codesign", "--verify", "--verbose=2", str(stapled))
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
            "--verbose=4", str(stapled))
        run("hdiutil", "verify", str(stapled), stdout=subprocess.DEVNULL)
        final_hash = digest(stapled)
        stapled.replace(final)

    record["final_sha256"] = final_hash
    write_json(record_path, record)
    report(final, record)


def report(final, record):
    print(f"Verified DMG: {final}")
    print(f"Apple status: Accepted ({record['submission_id']})")
    print(f"SHA-256: {record['final_sha256']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="start a new build for X.Y.Z")
    parser.add_argument("--resume", type=int, metavar="BUILD", help="continue the specified build")
    recovery = parser.add_mutually_exclusive_group()
    recovery.add_argument("--submission-id", type=UUID, help="recover a verified submission ID from Apple history")
    recovery.add_argument("--retry-submit", action="store_true", help="retry an upload after checking Apple history")
    args = parser.parse_args()
    if (args.version is None) == (args.resume is None):
        parser.error("Specify either a release version or --resume BUILD.")
    if args.version is not None and not RELEASE_VERSION.fullmatch(args.version):
        parser.error("The release version must be X.Y.Z with unpadded integers.")
    if args.resume is not None and args.resume < 1:
        parser.error("The build number must be positive.")
    if args.submission_id or args.retry_submit:
        if args.resume is None:
            parser.error("Recovery options require --resume BUILD.")
        if args.submission_id:
            args.submission_id = str(args.submission_id)

    RUNS.mkdir(parents=True, exist_ok=True)
    with (RUNS / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, "error: Another release is running in this checkout.\n")
        try:
            release(args, lock.fileno())
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
