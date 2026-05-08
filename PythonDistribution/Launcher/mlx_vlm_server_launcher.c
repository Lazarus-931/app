#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static int executable_path(char *buffer, size_t buffer_size) {
#ifdef __APPLE__
  uint32_t size = (uint32_t)buffer_size;
  char unresolved[PATH_MAX];
  if (_NSGetExecutablePath(unresolved, &size) != 0) {
    return -1;
  }
  if (realpath(unresolved, buffer) == NULL) {
    return -1;
  }
  return 0;
#elif defined(__linux__)
  ssize_t length = readlink("/proc/self/exe", buffer, buffer_size - 1);
  if (length < 0 || (size_t)length >= buffer_size) {
    return -1;
  }
  buffer[length] = '\0';
  return 0;
#else
  (void)buffer;
  (void)buffer_size;
  return -1;
#endif
}

static int dirname_in_place(char *path) {
  char *slash = strrchr(path, '/');
  if (slash == NULL) {
    return -1;
  }
  if (slash == path) {
    slash[1] = '\0';
  } else {
    *slash = '\0';
  }
  return 0;
}

static int join_path(char *buffer, size_t buffer_size, const char *left, const char *right) {
  int written = snprintf(buffer, buffer_size, "%s/%s", left, right);
  if (written < 0 || (size_t)written >= buffer_size) {
    return -1;
  }
  return 0;
}

int main(int argc, char **argv) {
  char exe_path[PATH_MAX];
  char root_dir[PATH_MAX];
  char python_home[PATH_MAX];
  char python_exe[PATH_MAX];

  if (executable_path(exe_path, sizeof(exe_path)) != 0) {
    fprintf(stderr, "failed to resolve executable path: %s\n", strerror(errno));
    return 127;
  }

  strncpy(root_dir, exe_path, sizeof(root_dir));
  root_dir[sizeof(root_dir) - 1] = '\0';
  if (dirname_in_place(root_dir) != 0 || dirname_in_place(root_dir) != 0) {
    fprintf(stderr, "failed to resolve distribution root from %s\n", exe_path);
    return 127;
  }

  if (join_path(python_home, sizeof(python_home), root_dir, "python") != 0 ||
      join_path(python_exe, sizeof(python_exe), python_home, "bin/python3") != 0) {
    fprintf(stderr, "distribution path is too long\n");
    return 127;
  }

  if (setenv("PYTHONHOME", python_home, 1) != 0 ||
      setenv("PYTHONNOUSERSITE", "1", 1) != 0) {
    fprintf(stderr, "failed to set Python environment: %s\n", strerror(errno));
    return 127;
  }

  char **child_argv = calloc((size_t)argc + 3, sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "failed to allocate launcher argv\n");
    return 127;
  }

  child_argv[0] = python_exe;
  child_argv[1] = "-m";
  child_argv[2] = "mlx_vlm.server";
  for (int i = 1; i < argc; i++) {
    child_argv[i + 2] = argv[i];
  }
  child_argv[argc + 2] = NULL;

  execv(python_exe, child_argv);
  fprintf(stderr, "failed to exec %s: %s\n", python_exe, strerror(errno));
  free(child_argv);
  return 127;
}
