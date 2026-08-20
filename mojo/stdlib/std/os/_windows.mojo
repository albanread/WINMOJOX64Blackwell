# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Windows implementation of `stat`, mirroring `_macos.mojo` and the Linux
variants.

The UCRT exposes `struct __stat64` through `_stat64`, which is the widest of
its several stat flavours: 64-bit sizes and 64-bit timestamps, so neither
files above 2 GB nor dates past 2038 are truncated. It carries considerably
less information than its POSIX counterparts, and the fields it lacks are
reported as zero rather than invented:

- `st_blocks` and `st_blksize` have no equivalent; the CRT does not report
  allocation granularity.
- `st_flags` is a BSD concept.
- Creation time is genuinely available on Windows, unlike Linux, but the CRT
  places it in `st_ctime` rather than exposing a separate field. It is
  therefore reported as both the status-change time (matching what the CRT
  provides) and the birth time (matching what it means).
- `st_uid`/`st_gid` are always zero from the CRT; Windows security is
  SID-based and does not map onto POSIX numeric ids.
"""

from std.ffi import external_call
from std.time.time import _CTimeSpec

from .fstat import stat_result

# UCRT <sys/stat.h> types. Note how narrow several of these are compared with
# their POSIX namesakes: st_ino is 16 bits and is not a meaningful file
# identity on Windows (GetFileInformationByHandle is), and the id and link
# fields are 16-bit signed.
comptime _dev_t = UInt32
comptime _ino_t = UInt16
comptime __time64_t = Int64


@fieldwise_init
struct _c_stat(Copyable, Defaultable, Writable):
    """Mirrors the UCRT's `struct __stat64`.

    Field order and widths must match exactly: `_stat64` writes through this
    pointer.
    """

    var st_dev: _dev_t
    """Drive number of the disk containing the file."""
    var st_ino: _ino_t
    """Not meaningful on Windows; always 0 from the CRT."""
    var st_mode: UInt16
    """File mode bits."""
    var st_nlink: Int16
    """Number of hard links; always 1 on non-NTFS."""
    var st_uid: Int16
    """Not meaningful on Windows; always 0."""
    var st_gid: Int16
    """Not meaningful on Windows; always 0."""
    var st_rdev: _dev_t
    """Drive number, same as st_dev."""
    var st_size: Int64
    """Size of the file in bytes."""
    var st_atime: __time64_t
    """Time of last access, in seconds since the Unix epoch."""
    var st_mtime: __time64_t
    """Time of last modification."""
    var st_ctime: __time64_t
    """Creation time on Windows, not status-change time as on POSIX."""

    def __init__(out self):
        self.st_dev = 0
        self.st_ino = 0
        self.st_mode = 0
        self.st_nlink = 0
        self.st_uid = 0
        self.st_gid = 0
        self.st_rdev = 0
        self.st_size = 0
        self.st_atime = 0
        self.st_mtime = 0
        self.st_ctime = 0

    def _to_stat_result(self) -> stat_result:
        return stat_result(
            st_dev=Int(self.st_dev),
            st_mode=Int(self.st_mode),
            st_nlink=Int(self.st_nlink),
            st_ino=Int(self.st_ino),
            st_uid=Int(self.st_uid),
            st_gid=Int(self.st_gid),
            st_rdev=Int(self.st_rdev),
            st_atimespec=_CTimeSpec(Int(self.st_atime), 0),
            st_ctimespec=_CTimeSpec(Int(self.st_ctime), 0),
            st_mtimespec=_CTimeSpec(Int(self.st_mtime), 0),
            # The CRT's st_ctime is the creation time, so it is also the
            # honest answer for birth time.
            st_birthtimespec=_CTimeSpec(Int(self.st_ctime), 0),
            st_size=Int(self.st_size),
            st_blocks=0,
            st_blksize=0,
            st_flags=0,
        )

    def write_to(self, mut writer: Some[Writer]):
        # fmt: off
        writer.write(
            "{\nst_dev: ", self.st_dev,
            ",\nst_ino: ", self.st_ino,
            ",\nst_mode: ", self.st_mode,
            ",\nst_nlink: ", self.st_nlink,
            ",\nst_uid: ", self.st_uid,
            ",\nst_gid: ", self.st_gid,
            ",\nst_rdev: ", self.st_rdev,
            ",\nst_size: ", self.st_size,
            ",\nst_atime: ", self.st_atime,
            ",\nst_mtime: ", self.st_mtime,
            ",\nst_ctime: ", self.st_ctime,
            "\n}",
        )
        # fmt: on


@always_inline
def _stat(var path: String) raises -> _c_stat:
    var stat = _c_stat()
    var err = external_call["_stat64", Int32](
        path.as_c_string_slice(), Pointer(to=stat)
    )
    if err == -1:
        raise Error("unable to stat '", path, "'")
    return stat^


@always_inline
def _lstat(var path: String) raises -> _c_stat:
    """Windows has no lstat.

    The CRT offers no way to stat a link without following it, and reparse
    points are not the same concept as POSIX symlinks. Following the link is
    the closer approximation, and is what CPython's os.lstat also falls back
    to for paths that are not reparse points.
    """
    return _stat(path^)
