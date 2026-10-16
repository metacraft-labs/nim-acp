#if defined(__linux__)
#define _GNU_SOURCE 1
#endif
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#include "owned_posix_child.h"
#include <sys/wait.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdio.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#else
extern char **environ;
#endif


#ifdef ACP_ADMISSION_DIAGNOSTICS
/* Control-only, caller-thread snapshot. No logging, signaling, or reaping.
 * Failure-only read occurs after the original admission outcome is fixed. */
struct acp_admission_diagnostic {
  int reader_fd, reader_fd_errno, reader_fl, reader_fl_errno;
  int writer_fd, writer_fd_errno, writer_fl, writer_fl_errno;
  int failure_probe_attempted, flags_result, flags_errno;
  int sigchld_query, sigchld_errno, sigchld_kind, sigchld_flags;
  int startup_error, received, poll_result, poll_errno, poll_revents;
  int nonblock_set, nonblock_errno, read_result, read_errno, read_child_errno;
  int restore_result, restore_errno, wait_result, wait_errno, wait_code, wait_status;
  long child_pid, wait_pid, session_result, group_result;
  int session_errno, group_errno;
};
static _Thread_local struct acp_admission_diagnostic admission_diagnostic;
const struct acp_admission_diagnostic *acp_admission_snapshot(void) {
  return &admission_diagnostic;
}
const char *acp_admission_snapshot_json(void) {
  static _Thread_local char text[4096];
  const struct acp_admission_diagnostic *d=&admission_diagnostic;
  int saved=errno;
  snprintf(text,sizeof text,
    "{\"schema\":1,\"attempted\":%d,\"readerFD\":%d,\"readerFDErrno\":%d,\"readerFL\":%d,\"readerFLErrno\":%d,"
    "\"writerFD\":%d,\"writerFDErrno\":%d,\"writerFL\":%d,\"writerFLErrno\":%d,"
    "\"sigchldQuery\":%d,\"sigchldErrno\":%d,\"sigchldKind\":%d,\"sigchldFlags\":%d,"
    "\"startupError\":%d,\"received\":%d,\"pollResult\":%d,\"pollErrno\":%d,\"revents\":%d,"
    "\"flagsResult\":%d,\"flagsErrno\":%d,\"nonblockSet\":%d,\"nonblockErrno\":%d,"
    "\"readResult\":%d,\"readErrno\":%d,\"readChildErrno\":%d,\"restoreResult\":%d,\"restoreErrno\":%d,"
    "\"waitResult\":%d,\"waitErrno\":%d,\"waitCode\":%d,\"waitStatus\":%d,\"childPID\":%ld,\"waitPID\":%ld,"
    "\"sessionResult\":%ld,\"groupResult\":%ld,\"sessionErrno\":%d,\"groupErrno\":%d}",
    d->failure_probe_attempted,d->reader_fd,d->reader_fd_errno,d->reader_fl,d->reader_fl_errno,
    d->writer_fd,d->writer_fd_errno,d->writer_fl,d->writer_fl_errno,
    d->sigchld_query,d->sigchld_errno,d->sigchld_kind,d->sigchld_flags,
    d->startup_error,d->received,d->poll_result,d->poll_errno,d->poll_revents,
    d->flags_result,d->flags_errno,d->nonblock_set,d->nonblock_errno,
    d->read_result,d->read_errno,d->read_child_errno,d->restore_result,d->restore_errno,
    d->wait_result,d->wait_errno,d->wait_code,d->wait_status,d->child_pid,d->wait_pid,
    d->session_result,d->group_result,d->session_errno,d->group_errno);
  errno=saved;return text;
}
static void admission_before_fork(int fds[2]) {
  struct acp_admission_diagnostic *d=&admission_diagnostic;
  struct sigaction action;
  memset(d,0,sizeof *d);
  d->poll_result=d->nonblock_set=d->read_result=d->restore_result=-2;
  d->wait_result=-2;d->session_result=d->group_result=-2;
  errno=0;d->reader_fd=fcntl(fds[0],F_GETFD);d->reader_fd_errno=errno;
  errno=0;d->reader_fl=fcntl(fds[0],F_GETFL);d->reader_fl_errno=errno;
  errno=0;d->writer_fd=fcntl(fds[1],F_GETFD);d->writer_fd_errno=errno;
  errno=0;d->writer_fl=fcntl(fds[1],F_GETFL);d->writer_fl_errno=errno;
  errno=0;d->sigchld_query=sigaction(SIGCHLD,NULL,&action);d->sigchld_errno=errno;
  if(!d->sigchld_query){
    d->sigchld_kind=action.sa_handler==SIG_DFL?0:action.sa_handler==SIG_IGN?1:2;
    d->sigchld_flags=action.sa_flags;
  }
}
static void admission_failed_snapshot(int fd,pid_t pid,int error,size_t received) {
  struct acp_admission_diagnostic *d=&admission_diagnostic;
  int saved=errno;struct pollfd ready={fd,POLLIN,0};siginfo_t info;
  d->failure_probe_attempted=1;
  d->startup_error=error;d->received=(int)received;d->child_pid=(long)pid;
  errno=0;d->poll_result=poll(&ready,1,0);d->poll_errno=errno;d->poll_revents=ready.revents;
  errno=0;int flags=fcntl(fd,F_GETFL);d->flags_result=flags;d->flags_errno=errno;
  if(flags>=0){errno=0;d->nonblock_set=fcntl(fd,F_SETFL,flags|O_NONBLOCK);d->nonblock_errno=errno;}
  d->read_result=-2;
  if(!d->nonblock_set){
    int value=0;errno=0;d->read_result=(int)read(fd,&value,sizeof value);d->read_errno=errno;
    if(d->read_result==(int)sizeof value)d->read_child_errno=value;
    errno=0;d->restore_result=fcntl(fd,F_SETFL,flags);d->restore_errno=errno;
  }
  memset(&info,0,sizeof info);errno=0;
  d->wait_result=waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT);d->wait_errno=errno;
  d->wait_pid=(long)info.si_pid;d->wait_code=info.si_code;d->wait_status=info.si_status;
  errno=0;d->session_result=(long)getsid(pid);d->session_errno=errno;
  errno=0;d->group_result=(long)getpgid(pid);d->group_errno=errno;
  errno=saved;
}
#endif

/* The leader is never reaped by polling. Its retained child identity pins the
 * session/group number until the final group signal has completed. A caller
 * must not independently reap this private child through a global SIGCHLD
 * handler. Such loss of ownership is a failure, never permission to signal. */
struct acp_owned_posix_child { pid_t pid; int input, output, error, reaped, drained, failed_exec; int closing, io_users; pthread_mutex_t state, writer, closer; };

static void drop(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }
/* Before fork: every descriptor is close-on-exec from its first publication.
 * No global fork lock or process-wide signal disposition is changed. */
static int pipe_cloexec(int fds[2], const char *temporary_parent) {
#if defined(__linux__)
  (void)temporary_parent;
  if (pipe2(fds, O_CLOEXEC) < 0) return errno;
#else
  /* O_CLOEXEC open is portable to the supported Darwin API. The exclusive
   * FIFO is unlinked with both ends open, retaining ordinary pipe semantics.
   * Native Darwin controls must prove these actual header/API contracts. */
  char directory[PATH_MAX]; int directory_fd=-1, e=0;
  if (!temporary_parent || temporary_parent[0]!='/') return EINVAL;
  if (snprintf(directory,sizeof directory,"%s/acp-pipe-XXXXXX",temporary_parent)>=(int)sizeof directory) return ENAMETOOLONG;
  if (!mkdtemp(directory)) return errno;
  directory_fd=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if (directory_fd<0) {e=errno;goto fifo_failed;}
  struct stat dir_stat, fifo_stat, opened;
  if(fstat(directory_fd,&dir_stat)<0){e=errno;goto fifo_failed;}
  if(dir_stat.st_uid!=geteuid() || (dir_stat.st_mode&0777)!=0700){e=EPERM;goto fifo_failed;}
  if(mkfifoat(directory_fd,"pipe",0600)<0){e=errno;goto fifo_failed;}
  if(fstatat(directory_fd,"pipe",&fifo_stat,AT_SYMLINK_NOFOLLOW)<0){e=errno;goto fifo_failed;}
  if(!S_ISFIFO(fifo_stat.st_mode) || fifo_stat.st_uid!=geteuid() || fifo_stat.st_nlink!=1){e=EPERM;goto fifo_failed;}
  fds[0]=openat(directory_fd,"pipe",O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
  if(fds[0]<0){e=errno;goto fifo_failed;}
  if(fstat(fds[0],&opened)<0){e=errno;goto fifo_failed;}
  if(opened.st_dev!=fifo_stat.st_dev || opened.st_ino!=fifo_stat.st_ino){e=ESTALE;goto fifo_failed;}
  fds[1]=openat(directory_fd,"pipe",O_WRONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);
  if(fds[1]<0){e=errno;goto fifo_failed;}
  if(fstat(fds[1],&opened)<0){e=errno;goto fifo_failed;}
  if(opened.st_dev!=fifo_stat.st_dev || opened.st_ino!=fifo_stat.st_ino){e=ESTALE;goto fifo_failed;}
  if(unlinkat(directory_fd,"pipe",0)<0){e=errno;goto fifo_failed;}
  for(int i=0;i<2;i++){
    int flags=fcntl(fds[i],F_GETFL,0);
    if(flags<0 || fcntl(fds[i],F_SETFL,flags&~O_NONBLOCK)<0){e=errno;goto fifo_failed;}
  }
  close(directory_fd);directory_fd=-1;
  if(rmdir(directory)<0){e=errno;goto fifo_failed;}
  goto fifo_ready;
fifo_failed:
  drop(&fds[0]);drop(&fds[1]);
  if(directory_fd>=0){unlinkat(directory_fd,"pipe",0);close(directory_fd);}
  rmdir(directory);return e;
fifo_ready:;
#endif
  for (int i=0;i<2;i++) {
    if (fds[i] < 3) {
      int replacement=fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
      if (replacement < 0) {int e=errno;drop(&fds[0]);drop(&fds[1]);return e;}
      close(fds[i]);fds[i]=replacement;
    }
  }
  return 0;
}

static long long millis(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) return -1;
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static int pause_poll(void) {
  struct timespec ts = {0, 10000000};
  /* Return to the absolute-deadline caller after EINTR. Repeated signals
   * must not restart a relative sleep and stretch the shutdown budget. */
  if (nanosleep(&ts, NULL) < 0 && errno != EINTR) return errno;
  return 0;
}
static int leader_alive(acp_owned_posix_child *c) {
  siginfo_t info;
  if (!c || c->reaped) return -ECHILD;
  memset(&info, 0, sizeof info);
  while (waitid(P_PID, (id_t)c->pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
    if (errno != EINTR) return -errno;
  }
  return info.si_pid == 0;
}
static int wait_alive_until(acp_owned_posix_child *c, long long end) {
  int alive, e;
  long long now;
  while ((alive=leader_alive(c)) > 0) {
    now=millis(); if (now < 0) return -errno;
    if (now >= end) return 1;
    if ((e=pause_poll())) return -e;
  }
  return alive;
}

int acp_owned_spawn(const char *image, char *const argv[], char *const env[],
                    const char *temporary_parent, acp_owned_posix_child **out) {
  int in[2] = {-1,-1}, output[2] = {-1,-1}, error[2] = {-1,-1};
  int admission[2] = {-1,-1}, e = 0;
  acp_owned_posix_child *c; int mutex_count=0;
  *out = NULL;
  if (!env) {
#if defined(__APPLE__)
    env=*_NSGetEnviron();
#else
    env=environ;
#endif
  }
  c = calloc(1, sizeof *c);
  if (!c) return ENOMEM;
  c->input = c->output = c->error = -1;
  if((e=pthread_mutex_init(&c->state,NULL)))goto failed;
  mutex_count++;
  if((e=pthread_mutex_init(&c->writer,NULL)))goto failed;
  mutex_count++;
  if((e=pthread_mutex_init(&c->closer,NULL)))goto failed;
  mutex_count++;
  if ((e=pipe_cloexec(in,temporary_parent)) ||
      (e=pipe_cloexec(output,temporary_parent)) ||
      (e=pipe_cloexec(admission,temporary_parent))) goto failed;
  /* stderr remains diagnostics, separate from protocol stdout. Duplicate its
   * actual caller sink atomically; never create an unread private stderr pipe. */
  error[1]=fcntl(STDERR_FILENO,F_DUPFD_CLOEXEC,3);
  if(error[1]<0){e=errno;goto failed;}
#ifdef ACP_ADMISSION_DIAGNOSTICS
  admission_before_fork(admission);
#endif
  c->pid = fork();
  if (c->pid < 0) { e=errno; goto failed; }
  if (c->pid == 0) {
    /* No Nim, allocation, PATH lookup, or shared-runtime lock after fork. */
    close(admission[0]);
    if (setsid() < 0 || dup2(in[0], STDIN_FILENO) < 0 ||
        dup2(output[1], STDOUT_FILENO) < 0 ||
        dup2(error[1], STDERR_FILENO) < 0) goto child_failed;
    close(in[0]); close(in[1]); close(output[0]); close(output[1]);
    close(error[0]); close(error[1]);
    execve(image, argv, env);
child_failed:
    e=errno;
    /* The bounded errno write is below PIPE_BUF; EINTR is retried. */
    while (write(admission[1], &e, sizeof e) < 0 && errno == EINTR) {}
    _exit(127);
  }
  drop(&in[0]); drop(&output[1]); drop(&error[1]); drop(&admission[1]);
  {
    unsigned char *dst=(unsigned char *)&e;
    size_t received=0;
    int read_error=0;
    long long admission_start=millis();
    if(admission_start < 0) { e=errno;read_error=1; }
    if(!read_error) {
      int admission_flags=fcntl(admission[0],F_GETFL,0);
      if(admission_flags < 0 ||
          fcntl(admission[0],F_SETFL,admission_flags|O_NONBLOCK) < 0) {
        e=errno;read_error=1;
      }
    }
    while (!read_error && received < sizeof e) {
      long long now=millis();
      if(now < 0) { e=errno;read_error=1;break; }
      long long remaining=admission_start+2000-now;
      if(remaining <= 0) { e=ETIMEDOUT;read_error=1;break; }
      /* Darwin FIFO poll can miss EOF after the CLOEXEC writer closes.
       * The nonblocking read is authoritative; poll only bounds the next
       * retry. A short poll timeout never replaces the absolute deadline. */
      ssize_t n=read(admission[0], dst+received, sizeof e-received);
      if (n == 0) break;
      if (n > 0) { received+=(size_t)n;continue; }
      if (errno==EINTR) continue;
      if (errno!=EAGAIN && errno!=EWOULDBLOCK) {
        e=errno;read_error=1;break;
      }
      now=millis();
      if(now < 0) { e=errno;read_error=1;break; }
      remaining=admission_start+2000-now;
      if(remaining <= 0) { e=ETIMEDOUT;read_error=1;break; }
      struct pollfd ready={admission[0],POLLIN,0};
      int available=poll(&ready,1,(int)(remaining < 10 ? remaining : 10));
      if(available < 0 && errno!=EINTR) {
        e=errno;read_error=1;break;
      }
    }
#ifdef ACP_ADMISSION_DIAGNOSTICS
    admission_diagnostic.startup_error=e;
    admission_diagnostic.received=(int)received;
    admission_diagnostic.child_pid=(long)c->pid;
    if(received==sizeof e)admission_diagnostic.read_child_errno=e;
    if(read_error)admission_failed_snapshot(admission[0],c->pid,e,received);
#endif
    drop(&admission[0]);
    if (read_error) {
      /* EOF was not observed, so application execution is uncertain. Retain
       * ownership for checked session/group shutdown; never assume that only
       * the direct child could exist after an admission-channel failure. */
      c->input=in[1];in[1]=-1;c->output=output[0];output[0]=-1;
      c->error=error[0];error[0]=-1;*out=c;return e;
    }
    if (received || e) {
      if (!e || received != sizeof e) e=EIO;
      /* A complete child errno record proves no application was entered.
       * Retain the private child for bounded checked direct-child cleanup,
       * including setsid failure. A partial record is uncertain execution. */
      c->failed_exec = received == sizeof e;
      c->input=in[1];in[1]=-1;c->output=output[0];output[0]=-1;
      c->error=error[0];error[0]=-1;*out=c;return e;
    }
  }
  c->input=in[1]; in[1]=-1;
  c->output=output[0]; output[0]=-1;
  c->error=error[0]; error[0]=-1;
  {
    int flags=fcntl(c->output, F_GETFL, 0);
    int input_flags=fcntl(c->input,F_GETFL,0);
    if (flags < 0 || input_flags < 0 ||
        fcntl(c->output,F_SETFL,flags|O_NONBLOCK)<0 ||
        fcntl(c->input,F_SETFL,input_flags|O_NONBLOCK)<0) {
      /* Return the owned handle even on post-exec setup failure. The caller
       * must complete checked shutdown before discarding this ownership. */
      e=errno; *out=c; return e;
    }
  }
  *out=c; return 0;
failed:
  drop(&in[0]);drop(&in[1]);drop(&output[0]);drop(&output[1]);
  drop(&error[0]);drop(&error[1]);drop(&admission[0]);drop(&admission[1]);
  if(mutex_count>2)pthread_mutex_destroy(&c->closer);
  if(mutex_count>1)pthread_mutex_destroy(&c->writer);
  if(mutex_count>0)pthread_mutex_destroy(&c->state);
  free(c); return e;
}
/* Admission counts include queued writers, so close cannot destroy their
 * descriptors or synchronization state. Short state locks never cover IO. */
static int io_enter(acp_owned_posix_child *c) {
  int e=pthread_mutex_lock(&c->state);if(e)return e;
  if(c->closing || c->drained)e=ECANCELED;else c->io_users++;
  int unlock=pthread_mutex_unlock(&c->state);return e?e:unlock;
}
static int io_leave(acp_owned_posix_child *c) {
  int e=pthread_mutex_lock(&c->state);if(e)return e;
  c->io_users--;return pthread_mutex_unlock(&c->state);
}
static int closing_state(acp_owned_posix_child *c,int *closing,int *users) {
  int e=pthread_mutex_lock(&c->state);if(e)return e;
  *closing=c->closing;*users=c->io_users;return pthread_mutex_unlock(&c->state);
}
int acp_owned_read(acp_owned_posix_child *c,unsigned char *byte) {
  int e=io_enter(c);if(e)return -e;
  ssize_t n=read(c->output,byte,1);int saved=errno;int leave=io_leave(c);
  if(leave)return -leave;
  if(n<0 && (saved==EAGAIN || saved==EWOULDBLOCK || saved==EINTR))return 0;
  return n<0?-saved:(int)n;
}
int acp_owned_write_frame(acp_owned_posix_child *c,const char *bytes,size_t length) {
  int e=io_enter(c);if(e)return e;
  e=pthread_mutex_lock(&c->writer);
  if(e){int leave=io_leave(c);return leave?leave:e;}
  size_t offset=0;
  while(offset<length) {
    int closing,users;
    if((e=closing_state(c,&closing,&users)))break;
    if(closing){e=ECANCELED;break;}
    /* The selected Nim runtime ignores SIGPIPE by default, as did the original
     * FileStream transport; no process-wide disposition is changed here. */
    ssize_t n=write(c->input,bytes+offset,length-offset);
    if(n>0){offset+=(size_t)n;continue;}
    if(n==0){e=EIO;break;}
    if(errno==EINTR)continue;
    if(errno!=EAGAIN && errno!=EWOULDBLOCK){e=errno;break;}
    struct pollfd ready={c->input,POLLOUT,0};
    int polled=poll(&ready,1,10);
    if(polled<0 && errno!=EINTR){e=errno;break;}
  }
  int unlock=pthread_mutex_unlock(&c->writer);int leave=io_leave(c);
  return e?e:(unlock?unlock:leave);
}
int acp_owned_alive(acp_owned_posix_child *c) {
  int e=pthread_mutex_lock(&c->state);if(e)return -e;
  int status=c->drained||c->closing?0:leader_alive(c);
  e=pthread_mutex_unlock(&c->state);return e?-e:status;
}
int acp_owned_drained(acp_owned_posix_child *c) {
  int e=pthread_mutex_lock(&c->state);if(e)return -e;
  int drained=c->drained;e=pthread_mutex_unlock(&c->state);
  return e?-e:drained;
}

static int signal_owned_group(acp_owned_posix_child *c, int signal_number) {
  int alive=leader_alive(c);
  if (alive < 0) return -alive;
  if (getsid(c->pid) != c->pid || getpgid(c->pid) != c->pid) return ECHILD;
  if (kill(-c->pid, signal_number) < 0 && errno != ESRCH) return errno;
  return 0;
}
static int publish_drained(acp_owned_posix_child *c) {
  int e=pthread_mutex_lock(&c->state);if(e)return e;
  c->drained=1;return pthread_mutex_unlock(&c->state);
}
static int close_quiet(acp_owned_posix_child *c, int graceful_ms, int terminal_ms) {
  long long start=millis(), end;
  int alive, e, status;
  if (!c) return 0;
  if (c->drained) return 0;
  if (start < 0) return errno;
  end=start+terminal_ms;
  if (c->reaped) goto observe_group;
  drop(&c->input);
  if (c->failed_exec) {
    /* No application exec occurred, hence no application descendants exist.
     * WNOWAIT verifies the unreaped direct-child identity before signalling. */
    alive=leader_alive(c);
    if (alive < 0) return -alive;
    if (alive && kill(c->pid,SIGKILL) < 0 && errno != ESRCH) return errno;
    alive=wait_alive_until(c,end);
    if (alive < 0) return -alive;
    if (alive) return ETIMEDOUT;
    pid_t waited;
    do { waited=waitpid(c->pid,&status,WNOHANG); } while(waited < 0 && errno==EINTR);
    if(waited < 0)return errno;
    if(waited != c->pid)return EAGAIN;
    c->reaped=1;drop(&c->output);drop(&c->error);return publish_drained(c);
  }
  end=start+graceful_ms;
  alive=wait_alive_until(c,end);
  if (alive < 0) return -alive;
  if ((e=signal_owned_group(c,SIGTERM))) return e;
  start=millis();if(start < 0)return errno;end=start+terminal_ms;
  /* Preserve a real TERM grace period even if the direct leader has already
   * exited. Its surviving group members still receive time to handle TERM. */
  for (;;) {
    long long now=millis();if(now < 0)return errno;
    if(now >= start+terminal_ms/2)break;
    if((e=pause_poll()))return e;
  }
  /* The leader still has not been reaped, so this group cannot be a newly
   * recycled group. SIGKILL also handles descendants ignoring SIGTERM. */
  if ((e=signal_owned_group(c,SIGKILL))) return e;
  alive=wait_alive_until(c,end);
  if (alive < 0) return -alive;
  if (alive) return ETIMEDOUT;
  while (waitpid(c->pid,&status,0) < 0) { if (errno != EINTR) return errno; }
  c->reaped=1;
observe_group:
  /* No signals after reaping. A reused foreign number can at worst cause a
   * visible timeout here; it can never become a target of cleanup. */
  while (kill(-c->pid,0) == 0 || errno == EPERM) {
    long long now=millis();if(now < 0)return errno;
    if (now >= end) return ETIMEDOUT;
    if ((e=pause_poll())) return e;
  }
  if (errno != ESRCH) return errno;
  drop(&c->output);drop(&c->error); return publish_drained(c);
}
int acp_owned_close(acp_owned_posix_child *c,int graceful_ms,int terminal_ms) {
  if(!c)return 0;
  int e=pthread_mutex_trylock(&c->closer);if(e)return e;
  long long start=millis();
  if(start<0){e=errno;goto finished;}
  e=pthread_mutex_lock(&c->state);if(e)goto finished;
  c->closing=1;
  e=pthread_mutex_unlock(&c->state);if(e)goto finished;
  /* No FILE flush precedes this deadline. Nonblocking writers observe closing
   * at most one polling quantum later; readers are single nonblocking syscalls. */
  for(;;){
    int closing,users;e=closing_state(c,&closing,&users);if(e)goto finished;
    if(!users)break;
    long long now=millis();if(now<0){e=errno;goto finished;}
    if(now>=start+graceful_ms){e=ETIMEDOUT;goto finished;}
    if((e=pause_poll()))goto finished;
  }
  long long now=millis();if(now<0){e=errno;goto finished;}
  int remaining=(int)(start+graceful_ms-now);if(remaining<0)remaining=0;
  e=close_quiet(c,remaining,terminal_ms);
finished:;
  int unlock=pthread_mutex_unlock(&c->closer);return e?e:unlock;
}
void acp_owned_free(acp_owned_posix_child *c) {
  /* The wrapper owns this immutable handle until its last reference dies.
   * Unresolved cleanup deliberately cannot be converted into a freed owner. */
  if(!c || !c->drained || c->io_users)return;
  drop(&c->input);drop(&c->output);drop(&c->error);
  if(pthread_mutex_destroy(&c->writer) || pthread_mutex_destroy(&c->state) ||
      pthread_mutex_destroy(&c->closer))return;
  free(c);
}
