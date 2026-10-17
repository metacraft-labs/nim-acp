/* Qualification fixture: real private sessions and surviving processes.
 * Only TERM/KILL denial is injected in the named sensitivity control;
 * every group-0 probe and final absence observation is an actual syscall. */
#define _GNU_SOURCE 1
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include "owned_posix_child.h"
static acp_owned_posix_child *fixture_owned;
static int fixture_is_reaped(void);
static int post_reap_signal_attempts;
static pid_t denied_group;
static int inject_denial, injected_term, injected_kill, actual_live_probes;
static int actual_term_success, actual_kill_success;
static int fixture_kill(pid_t target,int sig) {
  if(target==-denied_group && (sig==SIGTERM || sig==SIGKILL) && fixture_is_reaped())post_reap_signal_attempts++;
  if(inject_denial && target==-denied_group && (sig==SIGTERM || sig==SIGKILL)) {
    if(sig==SIGTERM)injected_term++;else injected_kill++;
    errno=EPERM;return -1;
  }
  int result=kill(target,sig),saved=errno;
  if(target==-denied_group && sig==0 && result==0)actual_live_probes++;
  if(target==-denied_group && sig==SIGTERM && result==0)actual_term_success++;
  if(target==-denied_group && sig==SIGKILL && result==0)actual_kill_success++;
  errno=saved;return result;
}
#define kill fixture_kill
#define ACP_ADMISSION_DIAGNOSTICS 1
#include "owned_posix_child.c"
#undef kill
static int fixture_is_reaped(void) { return fixture_owned && fixture_owned->reaped; }
static int receipt_fd=-1;
static void term_exit(int sig) { (void)sig;const char b='T';(void)write(receipt_fd,&b,1);_exit(0); }
static int read_byte_until(int fd,char *b,long long end) {
  while(millis()<end) {
    struct pollfd ready={fd,POLLIN,0};int r=poll(&ready,1,20);
    if(r>0){ssize_t n=read(fd,b,1);if(n==1)return 1;if(n==0)return 0;}
    else if(r<0 && errno!=EINTR)return 0;
  }
  return 0;
}
static int child_mode(const char *mode,int release_fd,int evidence_fd) {
  if(!strcmp(mode,"exit"))return 0;
  int ready[2];if(pipe(ready))return 90;
  pid_t descendant=fork();if(descendant<0)return 91;
  if(descendant==0) {
    close(ready[0]);receipt_fd=evidence_fd;
    struct sigaction action;memset(&action,0,sizeof action);sigemptyset(&action.sa_mask);
    action.sa_handler=!strcmp(mode,"term")?term_exit:SIG_IGN;
    if(sigaction(SIGTERM,&action,NULL))_exit(92);
    const char r='R';if(write(ready[1],&r,1)!=1)_exit(93);close(ready[1]);
    /* Every real survivor has a fixture-only release path. This also retires
     * TERM/KILL fixtures if an ownership assertion fails before API cleanup. */
    char b;while(read(release_fd,&b,1)<0 && errno==EINTR){};_exit(0);
  }
  close(ready[1]);char r=0;ssize_t n;
  do{n=read(ready[0],&r,1);}while(n<0 && errno==EINTR);
  close(ready[0]);if(n!=1 || r!='R')return 94;
  const char r2='R';if(write(evidence_fd,&r2,1)!=1)return 95;
  return 0; /* The genuine admitted leader becomes terminal; descendant remains. */
}
int main(int argc,char **argv) {
  if(argc==7 && !strcmp(argv[1],"--child")) {
    /* Observe the actual exec boundary, not merely the parent F_SETFD calls. */
    errno=0;if(fcntl(atoi(argv[5]),F_GETFD)!=-1 || errno!=EBADF)return 96;
    errno=0;if(fcntl(atoi(argv[6]),F_GETFD)!=-1 || errno!=EBADF)return 97;
    if(fcntl(atoi(argv[3]),F_GETFD)==-1 || fcntl(atoi(argv[4]),F_GETFD)==-1)return 98;
    if(strcmp(argv[2],"exit") && strcmp(argv[2],"term") && strcmp(argv[2],"kill") && strcmp(argv[2],"release"))return 64;
    return child_mode(argv[2],atoi(argv[3]),atoi(argv[4]));
  }
  if(argc!=2)return 64;
#ifdef ACP_CONTROL_OLD_REFERENCE
  if(strcmp(argv[1],"old-zombie"))return 64;
#else
  if(strcmp(argv[1],"zombie") && strcmp(argv[1],"live-term") && strcmp(argv[1],"live-kill") && strcmp(argv[1],"denied-live-injected"))return 64;
#endif
  struct sigaction inherited;memset(&inherited,0,sizeof inherited);
  if(sigaction(SIGCHLD,NULL,&inherited) || inherited.sa_handler!=SIG_DFL)return 66;
  struct sigaction pipe_action;memset(&pipe_action,0,sizeof pipe_action);
  pipe_action.sa_handler=SIG_IGN;sigemptyset(&pipe_action.sa_mask);
  if(sigaction(SIGPIPE,&pipe_action,NULL))return 67; /* Same fixture disposition as Nim runtime. */
  char first_snapshot[4096]="null";
  int release[2],evidence[2];if(pipe(release)||pipe(evidence))return 65;
  /* Parent-only endpoints must not survive exec into the private child.
   * If the fixture parent exits, release EOF still retires the real survivor. */
  if(fcntl(release[1],F_SETFD,FD_CLOEXEC)==-1 ||
      fcntl(evidence[0],F_SETFD,FD_CLOEXEC)==-1)return 65;
  char release_arg[32],evidence_arg[32];snprintf(release_arg,sizeof release_arg,"%d",release[0]);snprintf(evidence_arg,sizeof evidence_arg,"%d",evidence[1]);
  const int denied=!strcmp(argv[1],"denied-live-injected");
  const char *mode=denied?"release":(!strcmp(argv[1],"live-term")?"term":(!strcmp(argv[1],"live-kill")?"kill":"exit"));
  char parent_release_arg[32],parent_evidence_arg[32];
  snprintf(parent_release_arg,sizeof parent_release_arg,"%d",release[1]);
  snprintf(parent_evidence_arg,sizeof parent_evidence_arg,"%d",evidence[0]);
  char *child_argv[]={argv[0],"--child",(char*)mode,release_arg,evidence_arg,parent_release_arg,parent_evidence_arg,NULL};
  acp_owned_posix_child *c=NULL;int spawn=acp_owned_spawn(argv[0],child_argv,NULL,NULL,&c);
  fixture_owned=c;
  close(release[0]);close(evidence[1]);int failed=spawn!=0 || c==NULL;int first=-1,second=-1;char observed=0;
  if(!failed && strcmp(mode,"exit"))failed=!read_byte_until(evidence[0],&observed,millis()+3000)||observed!='R';
  if(!failed)failed=wait_alive_until(c,millis()+3000)!=0;
  if(!failed) {
    denied_group=c->pid;inject_denial=denied;
    first=acp_owned_close(c,1000,2000);
    snprintf(first_snapshot,sizeof first_snapshot,"%s",acp_admission_snapshot_json());
#ifdef ACP_CONTROL_OLD_REFERENCE
    if(strcmp(mode,"exit"))failed=1;
#ifdef __APPLE__
    if(first!=EPERM || acp_owned_drained(c))failed=1;
#else
    /* No old-negative credit on Linux: native Darwin must execute this case. */
    failed=1;
#endif
#else
    if(denied) {
      if(first!=ETIMEDOUT || acp_owned_drained(c) || injected_term!=1 || injected_kill!=1 || actual_live_probes==0)failed=1;
    } else if(first!=0 || !acp_owned_drained(c))failed=1;
    if(!strcmp(mode,"term") && actual_term_success!=1)failed=1;
    if(!strcmp(mode,"kill") && actual_kill_success!=1)failed=1;
    if(!strcmp(mode,"term")){char t=0;if(!read_byte_until(evidence[0],&t,millis()+1000)||t!='T')failed=1;}
#endif
  }
  /* Independent fixture release is always attempted, including failed assertions.
   * No numeric process/group signal follows consumption of the leader. */
  inject_denial=0;const char release_byte='X';(void)write(release[1],&release_byte,1);close(release[1]);
  if(c && !acp_owned_drained(c)) {
#ifdef ACP_CONTROL_OLD_REFERENCE
    if(!strcmp(mode,"exit")) {
      siginfo_t info;memset(&info,0,sizeof info);
      if(waitid(P_PID,(id_t)c->pid,&info,WEXITED|WNOHANG|WNOWAIT)==0 && info.si_pid==c->pid) {
        int status;pid_t waited;do{waited=waitpid(c->pid,&status,0);}while(waited<0&&errno==EINTR);
        if(waited!=c->pid)failed=1;
        c->reaped=1; /* Fixture-only external ownership cleanup, never API credit. */
      } else failed=1;
    }
#endif
    second=acp_owned_close(c,1000,2000);
    if(second!=0 || !acp_owned_drained(c))failed=1;
  }
  close(evidence[0]);
  if(post_reap_signal_attempts!=0)failed=1;
  printf("{\"mode\":\"%s\",\"spawn\":%d,\"firstClose\":%d,\"cleanupClose\":%d,\"injectedTERM\":%d,\"injectedKILL\":%d,\"actualLiveGroupProbes\":%d,\"postReapSignalAttempts\":%d,\"failed\":%d,\"firstSnapshot\":%s,\"cleanupSnapshot\":%s}\n",argv[1],spawn,first,second,injected_term,injected_kill,actual_live_probes,post_reap_signal_attempts,failed,first_snapshot,acp_admission_snapshot_json());
  if(c && acp_owned_drained(c))acp_owned_free(c);
  return failed?1:0;
}
