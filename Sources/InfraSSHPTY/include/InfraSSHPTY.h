#ifndef INFRA_SSH_PTY_H
#define INFRA_SSH_PTY_H
#include <sys/types.h>
typedef struct {
    pid_t pid;
    int terminal;
    int input;
    int output;
    int error;
    int exec_error;
    int terminal_keeper;
} infra_ssh_process;
int infra_ssh_spawn(const char *executable, char *const argv[], char *const envp[], infra_ssh_process *process);
int infra_ssh_has_exited(pid_t pid);
int infra_ssh_stop_and_reap(pid_t pid, int *status);
int infra_ssh_terminal_has_no_echo(int terminal);
#endif
