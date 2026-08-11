#include "nes_shm.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static nes_shm_t *map_fd(int fd) {
    void *p = mmap(NULL, sizeof(nes_shm_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : (nes_shm_t *)p;
}

nes_shm_t *nes_shm_create(const char *name) {
    shm_unlink(name); /* clear any stale segment from a crashed helper */
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0)
        return NULL;
    if (ftruncate(fd, sizeof(nes_shm_t)) != 0) {
        close(fd);
        shm_unlink(name);
        return NULL;
    }
    nes_shm_t *shm = map_fd(fd);
    if (!shm) {
        shm_unlink(name);
        return NULL;
    }
    memset(shm, 0, sizeof(*shm));
    shm->width = NES_SHM_WIDTH;
    shm->height = NES_SHM_HEIGHT;
    shm->version = NES_SHM_VERSION;
    nes_shm_store(&shm->front, 0);
    /* magic last: readers treat magic as the "segment ready" flag */
    __atomic_store_n(&shm->magic, NES_SHM_MAGIC, __ATOMIC_RELEASE);
    return shm;
}

nes_shm_t *nes_shm_open(const char *name) {
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(nes_shm_t)) {
        close(fd);
        return NULL;
    }
    nes_shm_t *shm = map_fd(fd);
    if (!shm)
        return NULL;
    if (__atomic_load_n(&shm->magic, __ATOMIC_ACQUIRE) != NES_SHM_MAGIC ||
        shm->version != NES_SHM_VERSION) {
        munmap(shm, sizeof(nes_shm_t));
        return NULL;
    }
    return shm;
}

void nes_shm_close(nes_shm_t *shm, const char *name, int is_creator) {
    if (shm)
        munmap(shm, sizeof(nes_shm_t));
    if (is_creator && name)
        shm_unlink(name);
}
