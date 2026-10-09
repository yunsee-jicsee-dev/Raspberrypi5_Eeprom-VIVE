#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vive-floppy-token 단위/통합 테스트 (이미지 파일 사용, 실물 플로피 불필요)."""

import errno
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "vive-floppy-token")


def load_tool():
    spec = importlib.util.spec_from_loader(
        "vivetoken", importlib.machinery.SourceFileLoader("vivetoken", TOOL))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


vt = load_tool()


def run_tool(*args, **kw):
    cmd = [sys.executable, TOOL] + list(args)
    return subprocess.run(cmd, capture_output=True, text=True,
                          env=kw.pop("env", None), check=False, **kw)


class TokenTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="vivetest.")
        self.img = os.path.join(self.tmp, "token.img")
        self.state = os.path.join(self.tmp, "state")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def format_token(self, *extra):
        res = run_tool("format", self.img, "--iter", "10000", *extra)
        self.assertEqual(res.returncode, 0, res.stderr)
        return res


class TestFormat(TokenTestCase):
    def test_creates_exact_floppy_size(self):
        self.format_token()
        self.assertEqual(os.path.getsize(self.img), vt.FLOPPY_BYTES)
        self.assertEqual(os.path.getsize(self.img), 1474560)

    def test_header_is_not_mountable_as_fat(self):
        """0x1FE 의 부트 시그니처가 없어야 OS 가 자동 마운트하지 않는다."""
        self.format_token()
        with open(self.img, "rb") as fh:
            sector = fh.read(512)
        self.assertEqual(sector[:8], vt.HDR_MAGIC)
        self.assertNotEqual(sector[0x1FE:0x200], b"\x55\xaa")

    def test_shards_are_scattered(self):
        self.format_token("--shards", "6")
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        self.assertEqual(len(hdr.shard_lbas), 6)
        self.assertNotIn(0, hdr.shard_lbas)
        self.assertNotIn(hdr.seq_lba, hdr.shard_lbas)
        self.assertNotIn(hdr.seq_lba_mirror, hdr.shard_lbas)
        # 연속 배치가 아니어야 한다: 최소 간격이 100 섹터보다 커야 한다.
        gaps = [b - a for a, b in zip(hdr.shard_lbas, hdr.shard_lbas[1:])]
        self.assertTrue(all(g > 100 for g in gaps), hdr.shard_lbas)

    def test_refuses_to_overwrite_without_force(self):
        self.format_token()
        res = run_tool("format", self.img, "--iter", "10000")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("--force", res.stderr)

    def test_empty_sectors_are_random_not_zero(self):
        """빈 영역이 0으로 남으면 키 영역의 위치가 드러난다."""
        self.format_token()
        with open(self.img, "rb") as fh:
            data = fh.read()
        self.assertLess(data.count(b"\0" * 512), 2)


class TestDerive(TokenTestCase):
    def test_passphrase_is_stable_and_hex(self):
        self.format_token()
        first = run_tool("derive", self.img)
        second = run_tool("derive", self.img)
        self.assertEqual(first.returncode, 0, first.stderr)
        key = first.stdout.strip()
        self.assertEqual(len(key), 64)
        int(key, 16)
        self.assertEqual(key, second.stdout.strip())

    def test_no_newline_option(self):
        self.format_token()
        res = run_tool("derive", "--no-newline", self.img)
        self.assertEqual(len(res.stdout), 64)
        self.assertNotIn("\n", res.stdout)

    def test_distinct_tokens_give_distinct_keys(self):
        self.format_token()
        a = run_tool("derive", self.img).stdout.strip()
        os.remove(self.img)
        self.format_token()
        b = run_tool("derive", self.img).stdout.strip()
        self.assertNotEqual(a, b)

    def test_pin_changes_key_and_is_required(self):
        self.format_token("--pin", "1234")
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        self.assertTrue(hdr.pin_required)
        right = run_tool("derive", "--pin", "1234", self.img).stdout.strip()
        wrong = run_tool("derive", "--pin", "4321", self.img).stdout.strip()
        self.assertEqual(len(right), 64)
        self.assertNotEqual(right, wrong)

    def test_pin_from_environment(self):
        self.format_token("--pin", "s3cret")
        env = dict(os.environ, VIVEBOOT_PIN="s3cret")
        res = run_tool("derive", self.img, env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout.strip(),
                         run_tool("derive", "--pin", "s3cret",
                                  self.img).stdout.strip())


class TestTamperDetection(TokenTestCase):
    def corrupt_byte(self, offset):
        with open(self.img, "r+b") as fh:
            fh.seek(offset)
            old = fh.read(1)
            fh.seek(offset)
            fh.write(bytes([old[0] ^ 0xFF]))

    def test_verify_passes_on_fresh_token(self):
        self.format_token()
        res = run_tool("verify", self.img)
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_header_corruption_detected(self):
        self.format_token()
        self.corrupt_byte(0x44)          # shard_count
        res = run_tool("verify", self.img)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("MAC", res.stderr)

    def test_shard_corruption_detected(self):
        self.format_token()
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        self.corrupt_byte(hdr.shard_lbas[2] * 512 + 0x10)
        res = run_tool("verify", self.img)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("shard", res.stderr)

    def test_wiped_shard_sector_detected(self):
        """조각 섹터를 0으로 밀면 magic 불일치로 잡힌다."""
        self.format_token()
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        with open(self.img, "r+b") as fh:
            fh.seek(hdr.shard_lbas[0] * 512)
            fh.write(b"\0" * 512)
        res = run_tool("verify", self.img)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("magic", res.stderr)

    def test_non_token_media_rejected(self):
        with open(self.img, "wb") as fh:
            fh.write(b"\0" * vt.FLOPPY_BYTES)
        res = run_tool("info", self.img)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("magic", res.stderr)


class TestSequenceCounter(TokenTestCase):
    def test_bump_increments_and_persists(self):
        self.format_token()
        self.assertEqual(run_tool("seq", "show", self.img).stdout.strip(), "1")
        self.assertEqual(run_tool("seq", "bump", self.img).stdout.strip(), "2")
        self.assertEqual(run_tool("seq", "show", self.img).stdout.strip(), "2")

    def test_bump_updates_both_copies(self):
        self.format_token()
        run_tool("seq", "bump", self.img)
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        ikm = vt.collect_ikm(self.img, hdr)
        _, mackey = vt.derive(ikm, hdr.salt, hdr.iter, "")
        primary = vt.unpack_seq(vt.read_sector(self.img, hdr.seq_lba), mackey)
        mirror = vt.unpack_seq(vt.read_sector(self.img, hdr.seq_lba_mirror),
                               mackey)
        self.assertEqual(primary, mirror)

    def test_state_file_mac_detects_forgery(self):
        self.format_token("--state", self.state)
        res = run_tool("verify", "--state", self.state, self.img)
        self.assertEqual(res.returncode, 0, res.stderr)
        with open(self.state, encoding="utf-8") as fh:
            body = fh.read()
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write(body.replace("seq=1", "seq=99"))
        res = run_tool("verify", "--state", self.state, self.img)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("MAC", res.stderr)

    def test_clone_divergence_is_reported(self):
        """복제본을 따로 쓰면 토큰 seq 와 기록된 seq 가 어긋난다."""
        self.format_token("--state", self.state)
        clone = os.path.join(self.tmp, "clone.img")
        shutil.copyfile(self.img, clone)
        # 원본으로 두 번 부팅한 것처럼 카운터를 올린다.
        run_tool("seq", "bump", "--state", self.state, self.img)
        run_tool("seq", "bump", "--state", self.state, self.img)
        # 복제본은 여전히 seq=1 -> 상태 파일(3)과 어긋난다.
        res = run_tool("verify", "--state", self.state, clone)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("복제", res.stdout)


class TestBackupRestore(TokenTestCase):
    def test_roundtrip_preserves_key(self):
        self.format_token()
        key = run_tool("derive", self.img).stdout.strip()
        backup = os.path.join(self.tmp, "backup.img")
        res = run_tool("backup", self.img, backup)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(os.path.getsize(backup), vt.FLOPPY_BYTES)
        self.assertEqual(os.stat(backup).st_mode & 0o777, 0o600)
        target = os.path.join(self.tmp, "restored.img")
        res = run_tool("restore", backup, target)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(run_tool("derive", target).stdout.strip(), key)

    def test_restore_rejects_wrong_size(self):
        bad = os.path.join(self.tmp, "bad.img")
        with open(bad, "wb") as fh:
            fh.write(b"\0" * 1024)
        res = run_tool("restore", bad, os.path.join(self.tmp, "out.img"))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("크기", res.stderr)


class TestWriteFailures(TokenTestCase):
    """실물 플로피에서 가장 흔한 실패는 쓰기 금지 탭과 불량 섹터다.

    그때 파이썬 traceback 이 뜨면 사용자는 무엇을 해야 할지 알 수 없다.
    (실제로 /dev/sdb 포맷 중 EIO traceback 이 보고되어 추가한 테스트다.)
    """

    def test_write_error_explains_write_protect(self):
        msg = vt.write_error(OSError(errno.EROFS, "ro"), "/dev/sdb", 0, 1)
        self.assertIn("읽기 전용", msg)
        self.assertIn("쓰기 금지 탭", msg)

    def test_write_error_explains_io_error(self):
        msg = vt.write_error(OSError(errno.EIO, "io"), "/dev/sdb", 49, 1)
        self.assertIn("섹터 49", msg)
        self.assertIn("dmesg", msg)          # 원인을 볼 방법을 알려 준다
        self.assertIn("쓰기 금지 탭", msg)

    def test_write_error_reports_sector_range(self):
        msg = vt.write_error(OSError(errno.EIO, "io"), "/dev/sdb", 128, 64)
        self.assertIn("섹터 128~191", msg)

    def test_write_error_explains_permission(self):
        msg = vt.write_error(OSError(errno.EACCES, "no"), "/dev/sdb", 0, 1)
        self.assertIn("sudo", msg)

    def test_write_error_explains_vanished_device(self):
        msg = vt.write_error(OSError(errno.ENODEV, "gone"), "/dev/sdb", 0, 1)
        self.assertIn("사라졌습니다", msg)

    def test_unknown_errno_still_actionable(self):
        msg = vt.write_error(OSError(errno.ESPIPE, "weird"), "/dev/sdb", 7, 1)
        self.assertIn("쓰기 실패", msg)
        self.assertIn("dmesg", msg)

    def test_format_on_failing_device_has_no_traceback(self):
        """/dev/full 은 쓰기에 ENOSPC 를 낸다. 실제 오류 경로를 끝까지 지난다."""
        if not os.path.exists("/dev/full"):
            self.skipTest("/dev/full 이 없다")
        res = run_tool("format", "/dev/full", "--iter", "10000", "--force")
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("Traceback", res.stderr)
        self.assertIn("오류:", res.stderr)

    def test_probe_runs_before_the_long_fill(self):
        """쓰기가 안 되면 2880섹터를 채우기 전에 끝나야 한다."""
        if not os.path.exists("/dev/full"):
            self.skipTest("/dev/full 이 없다")
        res = run_tool("format", "/dev/full", "--iter", "10000", "--force")
        self.assertNotIn("전체 2880 섹터를 난수로 채웁니다", res.stderr)

    def test_verify_written_catches_bad_media(self):
        """되읽기 검증이 조각 불일치를 잡는지 (헤더는 멀쩡한 채로)."""
        self.format_token()
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        ikm = vt.collect_ikm(self.img, hdr)
        _, mackey = vt.derive(ikm, hdr.salt, hdr.iter, "")
        vt.verify_written(self.img, hdr, ikm, mackey)      # 정상이면 통과
        with self.assertRaises(vt.TokenError) as cm:
            vt.verify_written(self.img, hdr, b"\0" * len(ikm), mackey)
        self.assertIn("부팅할 수 없습니다", str(cm.exception))


class TestCompactMode(TokenTestCase):
    """상한 트랙이 섞인 디스켓용 간이 모드 (--compact --at N)."""

    def test_places_shards_contiguously_at_given_sector(self):
        self.format_token("--compact", "--at", "15")
        hdr = vt.Header.unpack(vt.read_sector(self.img, 0))
        self.assertEqual(hdr.shard_lbas, [15, 16, 17, 18, 19, 20])
        self.assertEqual((hdr.seq_lba, hdr.seq_lba_mirror), (1, 2))

    def test_skips_full_random_fill(self):
        res = self.format_token("--compact")
        self.assertNotIn("전체 2880 섹터", res.stderr)
        self.assertIn("간이 모드", res.stderr)

    def test_compact_token_verifies_and_derives(self):
        self.format_token("--compact", "--at", "15")
        self.assertEqual(run_tool("verify", self.img).returncode, 0)
        self.assertEqual(len(run_tool("derive", self.img).stdout.strip()), 64)

    def test_rejects_at_overlapping_header_or_counters(self):
        res = run_tool("format", self.img, "--iter", "10000",
                       "--compact", "--at", "2")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("3 이상", res.stderr)

    def test_rejects_at_past_end_of_disk(self):
        res = run_tool("format", self.img, "--iter", "10000",
                       "--compact", "--at", "2877")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("넘습니다", res.stderr)


class TestBackupBadSectors(TokenTestCase):
    """상한 트랙이 있는 디스켓의 백업 (실물 /dev/sdb 에서 EIO 로 실패해 추가)."""

    def backup_with_bad(self, bad_lbas):
        real = vt.read_sector

        def flaky(path, lba, count=1):
            if any(lba <= b < lba + count for b in bad_lbas):
                raise vt.TokenError("simulated EIO at %d" % lba)
            return real(path, lba, count)

        out = os.path.join(self.tmp, "backup.img")
        args = type("A", (), {"device": self.img, "image": out,
                              "force": True})()
        vt.read_sector = flaky
        try:
            return out, vt.cmd_backup(args)
        finally:
            vt.read_sector = real

    def test_unused_bad_sectors_are_skipped(self):
        self.format_token("--compact", "--at", "15")
        key = run_tool("derive", self.img).stdout.strip()
        out, rc = self.backup_with_bad([100, 101, 2000])
        self.assertEqual(rc, 0)
        # 백업으로 복원해도 같은 키가 나와야 한다
        target = os.path.join(self.tmp, "restored.img")
        self.assertEqual(run_tool("restore", out, target).returncode, 0)
        self.assertEqual(run_tool("derive", target).stdout.strip(), key)

    def test_bad_token_sector_refuses_backup(self):
        self.format_token("--compact", "--at", "15")
        with self.assertRaises(vt.TokenError) as cm:
            self.backup_with_bad([17])
        self.assertIn("17", str(cm.exception))

    def test_compress_ranges(self):
        self.assertEqual(vt.compress_ranges([9, 3, 4, 5]), "3-5, 9")


class TestKdfVectors(unittest.TestCase):
    """파생식이 바뀌면 기존 토큰이 전부 못 쓰게 되므로 고정 벡터로 묶어 둔다.

    이 값들은 lib/viveboot-common.sh 의 vb_derive 와도 일치해야 한다
    (tests/test_crossimpl.sh 가 같은 벡터를 쉘 구현으로 확인한다).
    """

    IKM = bytes(range(32))
    SALT = bytes([0xAA] * 32)
    ITER = 1000
    KEY_NO_PIN = "17e9654b9c7c7675b2e69e1b6fa7ede559d7622705ee7664ec17f53066c604e9"
    KEY_PIN_1234 = "0abf837c9491614a16999894ceb90e5aaa7cc747d3e1726e688b7ea83401041a"
    MACKEY = "72a0fd6405d1a8bd51f158cc74bed45c3f5a2c86c7fc0b11af58b032586ce264"

    def test_vector_without_pin(self):
        key, mackey = vt.derive(self.IKM, self.SALT, self.ITER, "")
        self.assertEqual(key, self.KEY_NO_PIN)
        self.assertEqual(mackey.hex(), self.MACKEY)

    def test_vector_with_pin(self):
        key, mackey = vt.derive(self.IKM, self.SALT, self.ITER, "1234")
        self.assertEqual(key, self.KEY_PIN_1234)
        # mackey 는 PIN 과 무관하다 (ikm 만으로 정해진다).
        self.assertEqual(mackey.hex(), self.MACKEY)

    def test_iteration_count_matters(self):
        self.assertNotEqual(
            vt.derive(self.IKM, self.SALT, self.ITER + 1, "")[0],
            self.KEY_NO_PIN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
