"""Platform-native transport for Herdr's local control socket.

Herdr speaks newline-delimited JSON over a Unix domain socket. On native
Windows, Herdr 0.9.5 reports its socket as a file path under
%APPDATA%\\herdr\\sessions\\<name>\\herdr.sock, but nothing listens on that
path as an AF_UNIX socket (connect() is refused); Herdr serves a named pipe
whose name is that whole path: \\\\.\\pipe\\C:\\Users\\...\\herdr.sock
(both measured on windows-latest). pipe_name() maps the reported path to
that pipe, and an AF_UNIX connect through Winsock stays as the fallback.

The raw-socket helpers in this directory (herdr-eventwait.py,
herdr-agent-view.py, herdr-workspace-move.py) share this one module so each
keeps its own wire protocol and exit-status contract while the transport
follows the platform.

connect(path, timeout) returns an object with the subset of the socket API
those helpers use: settimeout(seconds), recv(n), sendall(data), close().
recv raises socket.timeout when the current timeout elapses and returns b""
when the peer closed the stream, exactly like a socket.

A Windows pipe handle opened without overlapped I/O serializes reads and
writes on one handle, so a blocking read would hold a later write forever.
Every helper writes its single request before it reads, so the pipe
connection starts its background reader on the first recv and refuses any
write after that point with OSError instead of deadlocking.
"""

import os
import queue
import socket
import sys
import threading
import time

WINDOWS = os.name == "nt"
_PIPE_PREFIXES = ("\\\\.\\pipe\\", "//./pipe/")
_PIPE_BUSY_RETRY = 0.05
_READ_CHUNK = 65536
_WINDOWS_AF_UNIX = 1


def is_pipe_path(path):
    return path.lower().startswith(_PIPE_PREFIXES)


def valid_path(path):
    """True for a control-socket path this platform can open: an absolute
    Unix socket path, or (on Windows) a named pipe or a drive-absolute path."""
    if not path or any(char in path for char in "\t\r\n\0"):
        return False
    if path.startswith("/"):
        return True
    if WINDOWS:
        if is_pipe_path(path):
            return True
        return len(path) > 2 and path[1] == ":" and path[2] in "\\/"
    return False


class _PipeConnection:
    def __init__(self, handle):
        self._handle = handle
        self._timeout = None
        self._chunks = queue.Queue()
        self._reader = None
        self._eof = False

    def settimeout(self, seconds):
        self._timeout = seconds

    def sendall(self, data):
        if self._reader is not None:
            raise OSError("herdr pipe: write after the reader started")
        self._handle.write(data)
        self._handle.flush()

    def _read_loop(self):
        try:
            while True:
                chunk = self._handle.read(_READ_CHUNK)
                if not chunk:
                    break
                self._chunks.put(chunk)
        except (OSError, ValueError):
            pass
        self._chunks.put(b"")

    def recv(self, _size):
        if self._eof:
            return b""
        if self._reader is None:
            self._reader = threading.Thread(target=self._read_loop, daemon=True)
            self._reader.start()
        try:
            chunk = self._chunks.get(timeout=self._timeout)
        except queue.Empty:
            raise socket.timeout("timed out")
        if not chunk:
            self._eof = True
        return chunk

    def close(self):
        try:
            self._handle.close()
        except OSError:
            pass


def _connect_pipe(path, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            # Unbuffered read/write binary handle on the pipe instance; the
            # server side owns message framing (newline-delimited JSON).
            handle = open(path, "r+b", buffering=0)
            return _PipeConnection(handle)
        except OSError as error:
            # ERROR_PIPE_BUSY (231): every instance is taken; wait for one.
            if getattr(error, "winerror", None) != 231 or time.monotonic() >= deadline:
                raise
            time.sleep(_PIPE_BUSY_RETRY)


def windows_path(path):
    """A drive path in Windows form: Git Bash's /c/Users/... becomes
    C:\\Users\\..., and forward slashes become backslashes."""
    if len(path) > 2 and path[0] == "/" and path[1].isalpha() and path[2] == "/":
        path = path[1].upper() + ":" + path[2:]
    elif len(path) == 2 and path[0] == "/" and path[1].isalpha():
        path = path[1].upper() + ":\\"
    return path.replace("/", "\\")


def pipe_name(path):
    """The named pipe Herdr serves for the socket path it reports: the
    pipe prefix followed by the whole Windows path."""
    return _PIPE_PREFIXES[0] + windows_path(path)


def _connect_windows_unix(path, timeout):
    """Connect to a Windows AF_UNIX socket file. Herdr on Windows serves its
    control socket as an AF_UNIX socket file (session list reports
    ...\\herdr\\sessions\\<name>\\herdr.sock), but CPython on Windows exposes
    no socket.AF_UNIX. Winsock itself supports AF_UNIX (Windows 10 1803+), so
    the socket is created and connected through ws2_32 and then adopted as a
    regular socket object, whose recv/sendall/settimeout need no address
    family support."""
    import ctypes

    ws2 = ctypes.WinDLL("ws2_32", use_last_error=True)
    ws2.socket.restype = ctypes.c_size_t
    ws2.socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    ws2.connect.restype = ctypes.c_int
    ws2.connect.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    ws2.closesocket.argtypes = [ctypes.c_size_t]
    ws2.WSAGetLastError.restype = ctypes.c_int

    class SockaddrUn(ctypes.Structure):
        _fields_ = [("sun_family", ctypes.c_ushort), ("sun_path", ctypes.c_char * 108)]

    encoded = path.encode("utf-8")
    if len(encoded) >= 108:
        raise OSError("herdr socket path is too long for AF_UNIX")
    handle = ws2.socket(_WINDOWS_AF_UNIX, socket.SOCK_STREAM, 0)
    if handle == ctypes.c_size_t(-1).value:
        raise OSError(ws2.WSAGetLastError(), "AF_UNIX socket() failed")
    address = SockaddrUn(_WINDOWS_AF_UNIX, encoded)
    if ws2.connect(handle, ctypes.byref(address), ctypes.sizeof(address)) != 0:
        error = ws2.WSAGetLastError()
        ws2.closesocket(handle)
        raise OSError(error, "AF_UNIX connect() failed")
    sock = socket.socket(fileno=handle)
    sock.settimeout(timeout)
    return sock


def connect(path, timeout):
    """Open the Herdr control socket at <path>; raise OSError on failure."""
    if WINDOWS and is_pipe_path(path):
        return _connect_pipe(path, timeout)
    if WINDOWS:
        try:
            return _connect_pipe(pipe_name(path), timeout)
        except FileNotFoundError:
            # No pipe by that name: try the path as an AF_UNIX socket file.
            pass
    family = getattr(socket, "AF_UNIX", None)
    if family is None:
        if WINDOWS:
            return _connect_windows_unix(path, timeout)
        raise OSError("this Python has no AF_UNIX support")
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(path)
    except OSError:
        sock.close()
        raise
    return sock


def lf_stdout():
    """Keep stdout LF-only: Windows text mode would turn each \\n into \\r\\n,
    and the Git Bash caller splits lines on \\n and compares exact fields."""
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        try:
            reconfigure(newline="\n")
        except (OSError, ValueError):
            pass
