#!/usr/bin/env python3
"""用两个独立签名进程验证共享钥匙串和容器，不读取真实会话或配置。"""

import argparse
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


PROBE_SOURCE = r'''
import Foundation
import Security

let arguments = CommandLine.arguments
let mode = arguments[1]
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: arguments[2],
    kSecAttrAccount as String: "synthetic-mount-verification",
    kSecAttrAccessGroup as String: arguments[3],
    kSecUseDataProtectionKeychain as String: true,
]
let fixture = Data([0x4c, 0x53, 0x54, 0x01])
var status: OSStatus
switch mode {
case "write":
    var attributes = query
    attributes[kSecValueData as String] = fixture
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    status = SecItemAdd(attributes as CFDictionary, nil)
case "read", "absent":
    var attributes = query
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if mode == "absent" {
        status = status == errSecItemNotFound ? errSecSuccess : errSecInternalComponent
    } else if status == errSecSuccess, result as? Data != fixture {
        status = errSecDecode
    }
case "delete":
    status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound { status = errSecSuccess }
case "container-write", "container-read", "container-delete", "container-absent":
    if let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: arguments[4]
    ) {
        let file = container.appendingPathComponent(arguments[2] + ".probe")
        do {
            switch mode {
            case "container-write": try fixture.write(to: file)
            case "container-read":
                guard try Data(contentsOf: file) == fixture else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            case "container-delete":
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            default:
                guard !FileManager.default.fileExists(atPath: file.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            status = errSecSuccess
        } catch { status = errSecIO }
    } else { status = errSecNotAvailable }
default:
    status = errSecParam
}
print("\(mode): \(status)")
exit(status == errSecSuccess ? 0 : 1)
'''


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def make_probe(source_bundle, destination, executable, identity):
    info = plistlib.loads((source_bundle / "Contents/Info.plist").read_bytes())
    entitlements = plistlib.loads(run(
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(source_bundle)
    ))
    bundle_id = info["CFBundleIdentifier"]
    team = entitlements["com.apple.developer.team-identifier"]
    if entitlements["com.apple.application-identifier"] != f"{team}.{bundle_id}":
        raise ValueError("签名中的应用身份不匹配")
    if not entitlements.get("com.apple.security.app-sandbox"):
        raise ValueError("验证目标必须启用沙盒")
    group = info["LanStashSharedKeychainAccessGroup"]
    if group not in entitlements["keychain-access-groups"]:
        raise ValueError("共享钥匙串访问组不匹配")
    app_group = info["LanStashAppGroupIdentifier"]
    if app_group not in entitlements["com.apple.security.application-groups"]:
        raise ValueError("共享容器访问组不匹配")
    contents = destination / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "MountProbe",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
    }))
    shutil.copy2(source_bundle / "Contents/embedded.provisionprofile", contents)
    shutil.copy2(executable, contents / "MacOS/MountProbe")
    entitlement_file = destination.parent / (destination.stem + ".entitlements")
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
        "--entitlements", str(entitlement_file), "--sign", identity, str(destination))
    run("/usr/bin/codesign", "--verify", "--strict", str(destination))
    return contents / "MacOS/MountProbe", group, app_group


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", required=True)
    arguments = parser.parse_args()
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(arguments.app))
    extension = arguments.app / "Contents/PlugIns/LanStashFileProvider.appex"
    with tempfile.TemporaryDirectory(prefix="lanstash-keychain-verification-") as directory:
        root = Path(directory)
        source = root / "Probe.swift"
        source.write_text(PROBE_SOURCE, encoding="utf-8")
        executable = root / "Probe"
        run("/usr/bin/xcrun", "swiftc", str(source), "-o", str(executable))
        main_probe, group, app_group = make_probe(arguments.app, root / "MainProbe.app", executable, arguments.identity)
        extension_probe, extension_group, extension_app_group = make_probe(extension, root / "ExtensionProbe.app", executable, arguments.identity)
        if group != extension_group or app_group != extension_app_group:
            raise ValueError("主 App 与扩展的共享访问组不同")
        # 每次只处理唯一服务名下的合成固定数据，绝不枚举或读取真实凭据。
        service = "LanStash.MountVerification." + str(uuid.uuid4())
        try:
            for probe, action in [
                (main_probe, "write"), (extension_probe, "read"),
                (extension_probe, "delete"), (main_probe, "absent"),
                (extension_probe, "write"), (main_probe, "read"),
                (main_probe, "container-write"), (extension_probe, "container-read"),
                (extension_probe, "container-delete"), (main_probe, "container-absent"),
                (extension_probe, "container-write"), (main_probe, "container-read"),
            ]:
                print(run(str(probe), action, service, group, app_group).decode().strip())
        finally:
            # 清理失败必须显式失败，不能声称合成凭据已移除。
            failures = []
            for action in ["delete", "container-delete", "absent", "container-absent"]:
                try:
                    run(str(main_probe), action, service, group, app_group)
                except subprocess.CalledProcessError as error:
                    failures.append(error)
            if failures:
                raise failures[0]
    print("两个独立沙盒签名进程可双向共享钥匙串和容器，合成数据与临时程序已清理；不代表 Finder/NAS 实机验收。")


if __name__ == "__main__":
    main()
