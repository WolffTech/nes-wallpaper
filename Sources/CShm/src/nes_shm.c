#include "nes_shm.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static nes_shm_t *map_fd(int fd, size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : (nes_shm_t *)p;
}

nes_shm_t *nes_shm_create(const char *path, uint32_t width, uint32_t height) {
    if (width == 0 || width > NES_SHM_MAX_WIDTH ||
        height == 0 || height > NES_SHM_MAX_HEIGHT)
        return NULL;
    size_t size = nes_shm_total_size(width, height);
    unlink(path); /* clear any stale file from a crashed helper */
    /* 0644: readers open the file read-only, and the screensaver plugin may
       run as a different sandbox identity than the writer. */
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0)
        return NULL;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        unlink(path);
        return NULL;
    }
    nes_shm_t *shm = map_fd(fd, size, PROT_READ | PROT_WRITE);
    if (!shm) {
        unlink(path);
        return NULL;
    }
    memset(shm, 0, size);
    shm->width = width;
    shm->height = height;
    shm->pitch = width * 4u;
    shm->version = NES_SHM_VERSION;
    nes_shm_store(&shm->front, 0);
    /* magic last: readers treat magic as the "segment ready" flag. The
       segment is already full-sized and dimensioned when it appears. */
    __atomic_store_n(&shm->magic, NES_SHM_MAGIC, __ATOMIC_RELEASE);
    return shm;
}

nes_shm_t *nes_shm_open(const char *path) {
    /* Read-only: readers never write, and the sandboxed screensaver reader
       could not open the file for writing anyway. */
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(nes_shm_t)) {
        close(fd);
        return NULL;
    }
    size_t mapped = (size_t)st.st_size;
    nes_shm_t *shm = map_fd(fd, mapped, PROT_READ);
    if (!shm)
        return NULL;
    /* >= not ==: accept a file larger than the header claims, refuse one
       too small for its own dimensions. */
    if (__atomic_load_n(&shm->magic, __ATOMIC_ACQUIRE) != NES_SHM_MAGIC ||
        shm->version != NES_SHM_VERSION ||
        shm->width == 0 || shm->width > NES_SHM_MAX_WIDTH ||
        shm->height == 0 || shm->height > NES_SHM_MAX_HEIGHT ||
        shm->pitch != shm->width * 4u ||
        mapped < nes_shm_total_size(shm->width, shm->height)) {
        munmap(shm, mapped);
        return NULL;
    }
    return shm;
}

void nes_shm_close(nes_shm_t *shm, const char *path, int is_creator) {
    if (shm)
        munmap(shm, nes_shm_total_size(shm->width, shm->height));
    if (is_creator && path)
        unlink(path);
}
