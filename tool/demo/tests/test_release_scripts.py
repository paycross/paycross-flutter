import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]


def fake_repo(tmp_path: Path, script: str) -> Path:
    """A throwaway git repo holding just the script under test.

    Hermetic on purpose: the real repo has no `demo-v0.1.0` tag, and a test
    that created one there would leave it behind.
    """
    (tmp_path / "tool" / "demo").mkdir(parents=True)
    (tmp_path / "example").mkdir()
    shutil.copy(REPO / "tool" / "demo" / script, tmp_path / "tool" / "demo" / script)

    def run(*args):
        return subprocess.run(args, cwd=tmp_path, check=True, capture_output=True)

    run("git", "init", "-q")
    run("git", "config", "user.email", "t@example.com")
    run("git", "config", "user.name", "t")
    (tmp_path / "README").write_text("x")
    run("git", "add", "-A")
    run("git", "commit", "-qm", "one")
    run("git", "tag", "demo-v0.1.0")
    return tmp_path


def dry_run(repo: Path, script: str, *args: str) -> str:
    done = subprocess.run(
        ["bash", str(repo / "tool" / "demo" / script), "--dry-run", *args],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    assert done.returncode == 0, done.stderr
    return done.stdout


@pytest.fixture
def ios_repo(tmp_path):
    return fake_repo(tmp_path, "release-ios.sh")


def test_the_version_flags_go_on_the_config_only_build(ios_repo):
    out = dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    config = next(line for line in out.splitlines() if "flutter build ios" in line)
    # --config-only is what writes Generated.xcconfig, which is what
    # Info.plist's $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER) resolve
    # against. Passing these to xcodebuild instead does nothing at all.
    assert "--config-only" in config
    assert "--build-name 0.1.0" in config
    assert "--build-number 1" in config
    assert "--build-name" not in out.split("xcodebuild")[1]


def test_the_config_only_build_never_tries_to_codesign(ios_repo):
    out = dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    config = next(line for line in out.splitlines() if "flutter build ios" in line)
    # The rig Mac has zero signing identities, and without this flag the
    # config-only step dies before `pod install` with "No development
    # certificates available to code sign app for device deployment".
    # Signing is xcodebuild's job here -- it is the half that carries the
    # API-key flags that let automatic signing create the certificate.
    assert "--no-codesign" in config


def test_an_explicit_build_number_wins_over_the_tag_count(ios_repo):
    out = dry_run(
        ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0", "--build-number", "21"
    )

    assert "--build-number 21" in out


def test_both_xcodebuild_calls_carry_the_auth_flags(ios_repo):
    out = dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    # Anchored on the command position, not on a substring anywhere in the
    # line: pytest names tmp_path after the test function, so REPO_ROOT
    # contains the word "xcodebuild" and the `git fetch` line would match too.
    calls = [line for line in out.splitlines() if line.startswith("+ xcodebuild")]
    assert len(calls) == 2
    for call in calls:
        assert "-allowProvisioningUpdates" in call
        assert "-authenticationKeyID Q8Y9M5TLY8" in call
        assert "-authenticationKeyIssuerID 92422d0e-885b-467d-b9f2-3f604eb503ba" in call
        assert "-authenticationKeyPath" in call


def test_neither_xcodebuild_call_pins_a_signing_identity(ios_repo):
    out = dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    # Pinning an identity does not override automatic signing's own choice, it
    # conflicts with it -- "Runner is automatically signed for development, but
    # a conflicting code signing identity ... has been manually specified",
    # measured on the rig Mac for every pod and Swift package target too. The
    # project-level default is what steers the choice.
    for call in [line for line in out.splitlines() if line.startswith("+ xcodebuild")]:
        assert "CODE_SIGN_IDENTITY" not in call


def test_the_dry_run_never_prints_the_key_path_or_any_key_material(ios_repo):
    out = dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    assert "<key-path>" in out
    assert ".p8" not in out
    assert "private_keys" not in out
    assert "BEGIN" not in out


def test_a_local_export_writes_no_upload_destination(ios_repo):
    dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0")

    options = plistlib.loads(
        (
            ios_repo / "build" / "demo" / "demo-v0.1.0-export" / "ExportOptions.plist"
        ).read_bytes()
    )
    assert options["method"] == "app-store-connect"
    assert options["signingStyle"] == "automatic"
    assert options["teamID"] == "53P7Y4G6TM"
    assert "destination" not in options


def test_upload_adds_exactly_one_key(ios_repo):
    dry_run(ios_repo, "release-ios.sh", "--tag", "demo-v0.1.0", "--upload")

    options = plistlib.loads(
        (
            ios_repo / "build" / "demo" / "demo-v0.1.0-export" / "ExportOptions.plist"
        ).read_bytes()
    )
    assert options["destination"] == "upload"
    assert options["method"] == "app-store-connect"


def test_a_tag_that_is_not_a_demo_tag_is_refused(ios_repo):
    done = subprocess.run(
        [
            "bash",
            str(ios_repo / "tool" / "demo" / "release-ios.sh"),
            "--dry-run",
            "--tag",
            "v0.1.0",
        ],
        cwd=ios_repo,
        capture_output=True,
        text=True,
    )

    assert done.returncode == 2
    assert "demo-v" in done.stderr


@pytest.fixture
def android_repo(tmp_path):
    return fake_repo(tmp_path, "release.sh")


def test_the_release_build_carries_the_tag_s_version(android_repo):
    out = dry_run(android_repo, "release.sh", "--tag", "demo-v0.1.0")

    build = next(line for line in out.splitlines() if "flutter build apk" in line)
    assert "--release" in build
    assert "--build-name 0.1.0" in build
    assert "--build-number 1" in build


def test_the_shipped_build_never_carries_the_automation_define(android_repo):
    out = dry_run(android_repo, "release.sh", "--tag", "demo-v0.1.0")

    assert "PAYCROSS_E2E" not in out


def test_the_e2e_build_carries_it_and_is_named_so_it_cannot_be_shipped(
    android_repo,
):
    out = dry_run(android_repo, "release.sh", "--tag", "demo-v0.1.0", "--e2e")

    assert "--dart-define=PAYCROSS_E2E=true" in out
    # A different filename, so the runner's build and the tester's build
    # cannot be confused for one another at the point somebody uploads one.
    assert "app-release-e2e.apk" in out
    assert "never attach" in out.lower()


def test_the_certificate_is_verified_before_anything_is_published(android_repo):
    out = dry_run(android_repo, "release.sh", "--tag", "demo-v0.1.0")

    lines = out.splitlines()
    verify = next(i for i, line in enumerate(lines) if "apksigner verify" in line)
    build = next(i for i, line in enumerate(lines) if "flutter build apk" in line)
    assert "--print-certs" in lines[verify]
    assert build < verify


def test_a_tag_that_is_not_a_demo_tag_is_refused_on_android_too(android_repo):
    done = subprocess.run(
        [
            "bash",
            str(android_repo / "tool" / "demo" / "release.sh"),
            "--dry-run",
            "--tag",
            "v0.1.0",
        ],
        cwd=android_repo,
        capture_output=True,
        text=True,
    )

    assert done.returncode == 2
