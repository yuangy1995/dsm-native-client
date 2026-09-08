#include <dlfcn.h>
#include <stdio.h>

/* 仅加载指定组件，不启动 App、不访问账号、配置或 NAS。 */
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    puts("library loaded");
    dlclose(library);
    return 0;
}
