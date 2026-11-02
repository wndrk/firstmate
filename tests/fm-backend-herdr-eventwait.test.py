#!/usr/bin/env python3
import importlib.util
import io
import socket
import time
import unittest
from pathlib import Path
from unittest import mock


READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")


TRANSPORT = READER.herdr_transport


class FakePipeHandle:
    """Stands in for a Windows named-pipe file handle."""

    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.written = b""
        self.closed = False

    def write(self, data):
        self.written += data

    def flush(self):
        pass

    def read(self, _size):
        return self.chunks.pop(0) if self.chunks else b""

    def close(self):
        self.closed = True


class HerdrTransportTest(unittest.TestCase):
    def test_unix_paths_stay_valid(self):
        self.assertTrue(TRANSPORT.valid_path("/tmp/herdr.sock"))
        self.assertFalse(TRANSPORT.valid_path(""))
        self.assertFalse(TRANSPORT.valid_path("relative.sock"))
        self.assertFalse(TRANSPORT.valid_path("/tmp/a\nb"))

    def test_pipe_paths_are_recognized(self):
        self.assertTrue(TRANSPORT.is_pipe_path("\\\\.\\pipe\\herdr-default"))
        self.assertTrue(TRANSPORT.is_pipe_path("//./pipe/herdr-default"))
        self.assertFalse(TRANSPORT.is_pipe_path("/tmp/herdr.sock"))

    def test_windows_accepts_pipe_and_drive_paths(self):
        with mock.patch.object(TRANSPORT, "WINDOWS", True):
            self.assertTrue(TRANSPORT.valid_path("\\\\.\\pipe\\herdr-default"))
            self.assertTrue(TRANSPORT.valid_path("C:\\Users\\me\\herdr.sock"))
            self.assertFalse(TRANSPORT.valid_path("C:herdr.sock"))
        with mock.patch.object(TRANSPORT, "WINDOWS", False):
            self.assertFalse(TRANSPORT.valid_path("\\\\.\\pipe\\herdr-default"))

    def test_pipe_connection_streams_then_reports_close(self):
        handle = FakePipeHandle([b'{"a":1}\n', b'{"b":2}\n'])
        conn = TRANSPORT._PipeConnection(handle)
        conn.sendall(b"request\n")
        self.assertEqual(handle.written, b"request\n")
        conn.settimeout(1)
        line, buf, outcome = READER._read_line(conn, b"", time.monotonic() + 1)
        self.assertEqual((line, outcome), (b'{"a":1}', "line"))
        line, buf, outcome = READER._read_line(conn, buf, time.monotonic() + 1)
        self.assertEqual((line, outcome), (b'{"b":2}', "line"))
        line, buf, outcome = READER._read_line(conn, buf, time.monotonic() + 1)
        self.assertEqual(outcome, "closed")

    def test_pipe_connection_times_out_like_a_socket(self):
        class Blocking(FakePipeHandle):
            def read(self, _size):
                time.sleep(5)
                return b""

        conn = TRANSPORT._PipeConnection(Blocking([]))
        conn.settimeout(0.05)
        with self.assertRaises(socket.timeout):
            conn.recv(1)

    def test_pipe_connection_refuses_write_after_read(self):
        conn = TRANSPORT._PipeConnection(FakePipeHandle([b"x\n"]))
        conn.settimeout(1)
        conn.recv(1)
        with self.assertRaises(OSError):
            conn.sendall(b"late\n")

    def test_lf_stdout_tolerates_plain_streams(self):
        with mock.patch.object(TRANSPORT.sys, "stdout", io.StringIO()):
            TRANSPORT.lf_stdout()


if __name__ == "__main__":
    unittest.main()
