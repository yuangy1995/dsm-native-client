"""使用合成安装包验证发布版本、来源、签名字段与失败关闭，不连接 GitHub。"""
import base64
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from macos_appcast import create_feed, FEED_URL, VALIDATION_FEED_URL, SPARKLE, version_tuple


class MacOSAppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "LanStash-0.2.6-universal.dmg"
        self.archive.write_bytes(b"synthetic archive")
        self.info = {
            "CFBundleShortVersionString": "0.2.6", "CFBundleVersion": "7",
            "LSMinimumSystemVersion": "14.0", "LanStashOnlineUpdatesEnabled": True,
            "SUFeedURL": FEED_URL,
            "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
        }
        self.signature = base64.b64encode(bytes(range(64))).decode()

    def feed(self, previous=None, tag="macos/v0.2.6"):
        return create_feed(self.info, self.archive, tag, self.signature, previous)

    def test_valid_feed_is_platform_specific_and_signed(self):
        item = ET.fromstring(self.feed()).find("./channel/item")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "7")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}minimumSystemVersion"), "14.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), self.signature)
        self.assertEqual(enclosure.get("length"), str(self.archive.stat().st_size))
        self.assertIn("/macos/v0.2.6/", enclosure.get("url"))
        self.assertNotIn("latest", enclosure.get("url"))

    def test_wrong_platform_or_version_tag_is_rejected(self):
        for tag in ["v0.2.6", "android/v0.2.6", "macos/v0.2.7", "macos/v0.2.6-beta.1"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.feed(tag=tag)

    def test_validation_feed_cannot_publish_to_stable_channel(self):
        self.info["SUFeedURL"] = VALIDATION_FEED_URL
        with self.assertRaises(ValueError):
            self.feed()
        feed = create_feed(self.info, self.archive, "macos-validation/v0.2.6", self.signature, validation=True)
        self.assertIn("/macos-validation/v0.2.6/", ET.fromstring(feed).find("./channel/item/enclosure").get("url"))
        self.info["SUFeedURL"] = FEED_URL
        with self.assertRaises(ValueError):
            create_feed(self.info, self.archive, "macos-validation/v0.2.6", self.signature, validation=True)

    def test_disabled_or_wrong_feed_is_rejected(self):
        for key, value in [("LanStashOnlineUpdatesEnabled", False), ("SUFeedURL", "https://example.invalid/feed")]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                with self.assertRaises(ValueError):
                    self.feed()
                self.info[key] = original

    def test_bad_keys_and_signatures_are_rejected(self):
        self.info["SUPublicEDKey"] = base64.b64encode(b"bad").decode()
        with self.assertRaises(ValueError):
            self.feed()
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.signature = "invalid"
        with self.assertRaises(ValueError):
            self.feed()

    def test_empty_archive_is_rejected(self):
        self.archive.write_bytes(b"")
        with self.assertRaises(ValueError):
            self.feed()

    def test_versions_must_both_increase(self):
        previous = Path(self.directory.name) / "previous.xml"
        for old_version, old_build, allowed in [
            ("0.2.5", "6", True), ("0.2.6", "6", False),
            ("0.2.5", "7", False), ("0.2.7", "6", False), ("0.2.5", "8", False),
        ]:
            root = ET.fromstring(self.feed())
            root.find(f"./channel/item/{{{SPARKLE}}}version").text = old_build
            root.find(f"./channel/item/{{{SPARKLE}}}shortVersionString").text = old_version
            previous.write_bytes(ET.tostring(root))
            with self.subTest(version=old_version, build=old_build):
                if allowed:
                    self.feed(previous)
                else:
                    with self.assertRaises(ValueError):
                        self.feed(previous)

    def test_malformed_existing_feed_is_not_silently_overwritten(self):
        previous = Path(self.directory.name) / "previous.xml"
        for contents in [b"<rss><channel/></rss>", b"<rss><channel><item/></channel></rss>"]:
            previous.write_bytes(contents)
            with self.assertRaises(ValueError):
                self.feed(previous)

    def test_numeric_version_comparison(self):
        self.assertGreater(version_tuple("10"), version_tuple("9.9"))
        self.assertEqual(version_tuple("7"), version_tuple("7.0.0"))
        with self.assertRaises(ValueError):
            version_tuple("7-beta")


if __name__ == "__main__":
    unittest.main()
