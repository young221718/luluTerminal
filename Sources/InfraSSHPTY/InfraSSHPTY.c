#include "InfraSSHPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <sys/wait.h>

int infra_ssh_spawn(const char *executable, char *const argv[], char *const envp[], infra_ssh_process *process) {
    int pipes[4][2] = {{-1,-1}, {-1,-1}, {-1,-1}, {-1,-1}};
    int master = -1, slave = -1;
    int descriptor_limit = getdtablesize();
    for (int i = 0; i < 4; i++) {
        if (pipe(pipes[i]) != 0) goto failed;
        for (int j = 0; j < 2; j++) {
            if (fcntl(pipes[i][j], F_SETFD, FD_CLOEXEC) == -1) goto failed;
        }
    }
    if (openpty(&master, &slave, NULL, NULL, NULL) != 0) goto failed;
    struct termios attributes;
    if (tcgetattr(slave, &attributes) != 0) goto failed;
    cfmakeraw(&attributes);
    if (tcsetattr(slave, TCSANOW, &attributes) != 0) goto failed;
    if (fcntl(slave, F_SETFD, FD_CLOEXEC) == -1) goto failed;
    int descriptors[] = {master, pipes[0][1], pipes[1][0], pipes[2][0], pipes[3][0]};
    for (int i = 0; i < 5; i++) {
        if (fcntl(descriptors[i], F_SETFD, FD_CLOEXEC) == -1 ||
            fcntl(descriptors[i], F_SETFL, O_NONBLOCK) == -1) goto failed;
    }
    if (fcntl(pipes[0][1], F_SETNOSIGPIPE, 1) == -1) goto failed;
    pid_t child = fork();
    if (child < 0) goto failed;
    if (child == 0) {
        // No Swift/Foundation runs after fork. login_tty creates our private session/group.
        if (login_tty(slave) == -1 ||
            dup2(pipes[0][0], STDIN_FILENO) == -1 ||
            dup2(pipes[1][1], STDOUT_FILENO) == -1 ||
            dup2(pipes[2][1], STDERR_FILENO) == -1 ||
            dup2(pipes[3][1], 3) == -1 || fcntl(3, F_SETFD, FD_CLOEXEC) == -1) {
            int code = errno;
            (void)write(pipes[3][1], &code, sizeof(code));
            _exit(127);
        }
        for (int fd = 4; fd < descriptor_limit; fd++) close(fd);
        execve(executable, argv, envp);
        int code = errno;
        (void)write(3, &code, sizeof(code));
        _exit(127);
    }
    close(pipes[0][0]); close(pipes[1][1]); close(pipes[2][1]); close(pipes[3][1]);
    // macOS needs a live slave reference after child stdio is replaced with separate pipes.
    *process = (infra_ssh_process){child, master, pipes[0][1], pipes[1][0], pipes[2][0], pipes[3][0], slave};
    return 0;
failed:;
    int code = errno;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++) if (pipes[i][j] >= 0) close(pipes[i][j]);
    if (master >= 0) close(master);
    if (slave >= 0) close(slave);
    return code;
}

int infra_ssh_has_exited(pid_t pid) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == -1) return errno == EINTR ? 0 : -1;
    return info.si_pid == pid;
}

int infra_ssh_stop_and_reap(pid_t pid, int *status) {
    // Keep the leader unreaped until its owned group is stopped, preventing PID reuse.
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    pid_t waited;
    do { waited = waitpid(pid, status, 0); } while (waited < 0 && errno == EINTR);
    return waited == pid ? 0 : -1;
}

int infra_ssh_terminal_has_no_echo(int terminal) {
    struct termios attributes;
    return tcgetattr(terminal, &attributes) == 0 && (attributes.c_lflag & (ECHO | ECHONL)) == 0;
}
