"""Observe one Linux runtime-acquisition command without changing its argv or limits.

Only the direct client is waited/signalled. Nix daemon/build processes are not
owned here. Shared-cgroup or host counter changes do not identify an OOM victim.
Without wrapper cancellation, observation errors are secondary to the command's
original exit status. A received TERM/INT deliberately makes the wrapper fail
with128+signal even when the client handles it and exits normally; raw client
and original shell-facing status remain separately recorded.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import stat
import subprocess
import sys
import time

LIMIT = 8192
COUNTERS = (
    'memory.events', 'memory.events.local', 'memory.current', 'memory.peak',
    'memory.max', 'memory.swap.current', 'memory.swap.max', 'pids.current',
    'pids.max',
)


class UnsupportedWaitContext(RuntimeError):
    pass


def error_row(error):
    return {'type': type(error).__name__, 'errno': getattr(error, 'errno', None),
            'message': str(error)[:512]}


def read_bounded(path, directory=None):
    fd = None
    result = {}
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        body = os.read(fd, LIMIT + 1)
        retained = body[:LIMIT]
        result = {'text': retained.decode('utf-8', errors='replace'),
                  'retainedBytes': len(retained), 'truncated': len(body) > LIMIT,
                  'retainedSHA256': hashlib.sha256(retained).hexdigest()}
    except Exception as error:
        result = {'error': error_row(error)}
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception as error:
                result['closeError'] = error_row(error)
    return result


def process_sample(pid):
    try:
        root = Path('/proc') / str(pid)
        first = (root / 'stat').read_text().rsplit(')', 1)[1].split()
        membership = (root / 'cgroup').read_text()
        image = os.readlink(root / 'exe')
        second = (root / 'stat').read_text().rsplit(')', 1)[1].split()
        if first[19] != second[19]:
            raise RuntimeError('Process generation changed during observation')
        return {'PID': pid, 'birth': int(second[19]), 'state': second[0],
                'cgroup': membership, 'exe': image,
                'precision': 'Point observation only; later migration/exec may occur'}
    except Exception as error:
        return {'PID': pid, 'error': error_row(error)}


def observe(argv, receipt_directory):
    report = {'argv': argv, 'cwd': os.getcwd(), 'startedMonotonic': time.monotonic(),
              'errors': [], 'signals': [], 'signalCount': 0,
              'scope': 'Direct client only; counters are non-atomic observations, '
                        'not a victim attribution or a resource-admission proof'}
    child = None
    child_fd = None
    group_fd = None
    receipt_fd = None
    old_handlers = {}
    forwarded = 0
    child_return = None

    def note(where, error):
        if len(report['errors']) < 32:
            report['errors'].append({'where': where, **error_row(error)})

    def received(signum, frame):
        report['signalCount'] += 1
        if len(report['signals']) < 32:
            report['signals'].append(signum)
        # Never raise inside Popen before its actual child handle is assigned.

    def snapshot():
        value = {'startedMonotonic': time.monotonic(),
                  'meminfo': read_bounded('/proc/meminfo'),
                  'vmstat': read_bounded('/proc/vmstat'),
                  'selfCgroup': read_bounded('/proc/self/cgroup')}
        if group_fd is not None:
            try:
                held = os.fstat(group_fd)
                value['heldCgroup'] = {'device': held.st_dev, 'inode': held.st_ino,
                                      'link': os.readlink('/proc/self/fd/' + str(group_fd))}
                value['counters'] = {name: read_bounded(name, group_fd) for name in COUNTERS}
            except Exception as error:
                value['cgroupError'] = error_row(error)
        try:
            space = os.statvfs('.')
            value['availableDiskBytes'] = space.f_bavail * space.f_frsize
        except Exception as error:
            value['diskError'] = error_row(error)
        value['finishedMonotonic'] = time.monotonic()
        return value

    try:
        try:
            receipt_fd = os.open(str(receipt_directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            held = os.fstat(receipt_fd)
            if not stat.S_ISDIR(held.st_mode) or held.st_uid != os.getuid():
                raise RuntimeError('Observation destination must be an owned directory')
            report['receiptDirectoryIdentity'] = [held.st_dev, held.st_ino, held.st_uid]
        except Exception as error:
            note('receipt-directory', error)
            if receipt_fd is not None:
                refused_fd = receipt_fd
                receipt_fd = None
                try:
                    os.close(refused_fd)
                except Exception as close_error:
                    note('close-refused-receipt-directory', close_error)
        try:
            rows = Path('/proc/self/cgroup').read_text().splitlines()
            if len(rows) != 1 or not rows[0].startswith('0::/'):
                raise RuntimeError('No single unified cgroup membership observed')
            membership = rows[0][3:]
            if '..' in membership.split('/'):
                raise RuntimeError('Invalid kernel cgroup path')
            group_fd = os.open('/sys/fs/cgroup' + membership,
                                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            report['observedCgroupPath'] = membership
        except Exception as error:
            note('open-held-cgroup', error)
        disposition = signal.getsignal(signal.SIGCHLD)
        report['inheritedSIGCHLD'] = int(disposition) if isinstance(disposition, int) else repr(disposition)
        try:
            task_count = len(os.listdir('/proc/self/task'))
        except Exception as error:
            report['unsupportedWaitContext'] = 'Cannot establish a single-threaded wait owner'
            report['prelaunchShellExit'] = 125
            raise UnsupportedWaitContext(report['unsupportedWaitContext']) from error
        report['actualOwnerThreadCount'] = task_count
        if disposition != signal.SIG_DFL or task_count != 1:
            report['unsupportedWaitContext'] = 'Require inherited default SIGCHLD and one wait-owner thread; do not reset child context'
            report['prelaunchShellExit'] = 125
            raise UnsupportedWaitContext(report['unsupportedWaitContext'])
        for signum in (signal.SIGTERM, signal.SIGINT):
            old_handlers[signum] = signal.signal(signum, received)
        try:
            report['before'] = snapshot()
        except Exception as error:
            note('before-snapshot', error)
        if report['signals']:
            report['cancelledBeforeLaunch'] = True
        else:
            try:
                child = subprocess.Popen(argv)  # Same cwd/env/stdin/stdout/stderr and process group.
                report['childPID'] = child.pid
                try:
                    child_fd = os.pidfd_open(child.pid)
                    report['retainedClientPidfd'] = True
                except Exception as error:
                    note('client-pidfd', error)  # Actual Popen handle remains owned.
                report['clientObservation'] = process_sample(child.pid)
            except Exception as error:
                note('spawn', error)
                report['spawnShellExit'] = 127 if isinstance(error, FileNotFoundError) else 126
            if child is not None:
                while True:
                    while forwarded < len(report['signals']):
                        signum = report['signals'][forwarded]
                        forwarded += 1
                        try:
                            if child_fd is not None:
                                signal.pidfd_send_signal(child_fd, signum)
                            else:
                                child.send_signal(signum)  # Sole direct-child wait owner; no numeric outsider.
                        except ProcessLookupError:
                            pass
                        except Exception as error:
                            note('forward-received-signal', error)
                    try:
                        child_return = child.wait(timeout=0.1)
                        break
                    except subprocess.TimeoutExpired:
                        pass
    except Exception as error:
        note('observer', error)
    finally:
        # Observation/pidfd errors must never discard an actual child handle.
        if child is not None and child_return is None:
            while True:
                try:
                    child_return = child.wait(timeout=0.1)
                    break
                except subprocess.TimeoutExpired:
                    while forwarded < len(report['signals']):
                        signum = report['signals'][forwarded]
                        forwarded += 1
                        try:
                            child.send_signal(signum)
                        except ProcessLookupError:
                            pass
                        except Exception as error:
                            note('cleanup-forward-signal', error)
        if child_fd is not None:
            try:
                os.close(child_fd)
            except Exception as error:
                note('close-client-pidfd', error)
        # No live direct child remains. Restore ordinary signal behavior during
        # best-effort diagnostic serialization; no universal cancellation claim.
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        try:
            report['after'] = snapshot()
        except Exception as error:
            note('after-snapshot', error)
        report['rawClientReturncode'] = child_return
        report['directClientReaped'] = child is not None and child_return is not None
        report['originalShellFacingExit'] = (128 - child_return if child_return < 0 else child_return) if child_return is not None else report.get('spawnShellExit')
        status = report['originalShellFacingExit']
        if report['signals']:
            status = 128 + report['signals'][0]
        if status is None:
            status = report.get('prelaunchShellExit', 125)
        report['wrapperExit'] = status
        report['finishedMonotonic'] = time.monotonic()
        if group_fd is not None:
            try:
                os.close(group_fd)
            except Exception as error:
                note('close-held-cgroup', error)
        if receipt_fd is not None:
            try:
                body = (json.dumps(report, indent=2) + '\n').encode()
                if len(body) > 256 * 1024:
                    raise RuntimeError('Bounded resource observation exceeded256KiB')
                fd = os.open('runtime-build-observation.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                              0o600, dir_fd=receipt_fd)
                with os.fdopen(fd, 'wb') as output:
                    output.write(body)
                    output.flush()
                    os.fsync(output.fileno())
            except Exception as error:
                sys.stderr.write('Secondary runtime observation failure: ' + str(error)[:512] + '\n')
            finally:
                try:
                    os.close(receipt_fd)
                except Exception as error:
                    sys.stderr.write('Secondary observation-directory close failure: ' + str(error)[:512] + '\n')
    return status


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt-directory', required=True, type=Path)
    parser.add_argument('argv', nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.argv
    if command[:1] == ['--']:
        command = command[1:]
    if not command or sys.platform != 'linux':
        parser.error('A command on Linux is required')
    raise SystemExit(observe(command, arguments.receipt_directory))
