"""Distribution invariants, independent of macOS or a browser build."""

import importlib.util
import plistlib
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "webkit_package", Path(__file__).with_name("package-webkit-sdk.py")
)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


@pytest.fixture
def build(tmp_path):
    build = tmp_path / "build"
    for name in packaging.REQUIRED_FRAMEWORKS:
        framework = build / f"{name}.framework"
        (framework / "Versions/A").mkdir(parents=True)
        (framework / "Versions/A" / name).write_bytes(b"binary")
        (framework / "Versions/Current").symlink_to("A")
        (framework / name).symlink_to(f"Versions/Current/{name}")
    (build / "WebCore.framework/Frameworks").symlink_to("Versions/Current/Frameworks")
    services = build / "WebKit.framework/Versions/A/XPCServices"
    services.mkdir()
    for name in packaging.REQUIRED_SERVICES:
        bundle = build / name / "Contents"
        (bundle / "MacOS").mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "service"})
        )
        (bundle / "MacOS/service").write_bytes(b"executable")
        (services / name).symlink_to("../../../../" + name)
    return build


def test_framework_and_subprocess_links_survive_relocation(build, tmp_path):
    stage = tmp_path / "sdk/lib"
    packaging.copy_products(build, stage)
    moved = tmp_path / "relocated"
    stage.parent.rename(moved)
    build.rename(tmp_path / "hidden-build")
    packaging.validate_links(moved)
    assert (moved / "lib/WebCore.framework/Frameworks").is_dir()
    assert (moved / "lib/WebKit.framework/WebKit").read_bytes() == b"binary"
    assert (
        moved
        / "lib/WebKit.framework/Versions/A/XPCServices"
        / packaging.REQUIRED_SERVICES[0]
    ).is_dir()


def test_missing_subprocess_executable_is_rejected(build, tmp_path):
    (build / packaging.REQUIRED_SERVICES[0] / "Contents/MacOS/service").unlink()
    with pytest.raises(RuntimeError, match="Missing browser subprocess executable"):
        packaging.copy_products(build, tmp_path / "output")


@pytest.mark.parametrize(
    "link", ["/usr/lib/libSystem.B.dylib", "../outside", "missing"]
)
def test_nonportable_or_dangling_links_are_rejected(tmp_path, link):
    stage = tmp_path / "sdk"
    stage.mkdir()
    (tmp_path / "outside").write_text("outside")
    (stage / "bad").symlink_to(link)
    with pytest.raises(RuntimeError, match="SDK symlink"):
        packaging.validate_links(stage)


def test_manifest_detects_corruption_missing_files_and_added_files(build, tmp_path):
    root = tmp_path / "source"
    license = root / "Source/JavaScriptCore/COPYING.LIB"
    license.parent.mkdir(parents=True)
    license.write_text("license text")
    stage = tmp_path / "sdk"
    packaging.package(root, build, stage, "webkit-v-test", "a" * 40, "27.0")
    manifest = packaging.verify_package(stage)
    assert manifest["commit"] == "a" * 40
    assert (
        stage / "share/licenses/Source/JavaScriptCore/COPYING.LIB"
    ).read_text() == "license text"
    info = stage / "BUILD-INFO.txt"
    original = info.read_text()
    info.write_text("wrong revision")
    with pytest.raises(RuntimeError, match="manifest"):
        packaging.verify_package(stage)
    info.unlink()
    with pytest.raises(RuntimeError, match="manifest"):
        packaging.verify_package(stage)
    info.write_text(original)
    (stage / "unexpected").write_text("extra file")
    with pytest.raises(RuntimeError, match="manifest"):
        packaging.verify_package(stage)


def test_jsc_public_headers_use_cmake_staging_directory(tmp_path):
    spec = importlib.util.spec_from_file_location(
        "jsc_package", Path(__file__).with_name("package-jsc-sdk.py")
    )
    jsc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(jsc)
    build = tmp_path / "build"
    headers = build / "JavaScriptCore/Headers/JavaScriptCore"
    headers.mkdir(parents=True)
    for name in jsc.PUBLIC_HEADERS:
        (headers / name).write_text(name)
    output = tmp_path / "sdk"
    jsc.copy_headers(build, output)
    assert (output / "include/JavaScriptCore/JSBase.h").read_text() == "JSBase.h"
