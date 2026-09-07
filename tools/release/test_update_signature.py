"""使用 RFC 8032 公开测试向量验证签名门禁，不接触项目私钥。"""
import base64
from pathlib import Path
import subprocess
import tempfile
import unittest


class UpdateSignatureTests(unittest.TestCase):
    def test_signature_and_tampered_archive(self):
        root = Path(__file__).resolve().parents[2]
        public_key = base64.b64encode(bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        )).decode()
        signature = base64.b64encode(bytes.fromhex(
            "e5564300c360ac729086e2cc806e828a"
            "84877f1eb8e5d974d873e065224901555"
            "fb8821590a33bacc61e39701cf9b46bd"
            "25bf5f0595bbe24655141438e7a100b"
        )).decode()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "fixture"
            archive.write_bytes(b"")
            command = ["swift", str(root / "tools/release/verify_update_signature.swift"),
                       str(archive), public_key, signature]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            archive.write_bytes(b"tampered")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            archive.write_bytes(b"")
            command[-2] = base64.b64encode(bytes(32)).decode()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
