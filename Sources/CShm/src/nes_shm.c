#include "nes_shm.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static nes_shm_t *map_fd(int fd, size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : (nes_shm_t *)p;
}

nes_shm_t *nes_shm_create(const char *name, uint32_t width, uint32_t height) {
    if (width == 0 || width > NES_SHM_MAX_WIDTH ||
        height == 0 || height > NES_SHM_MAX_HEIGHT)
        return NULL;
    size_t size = nes_shm_total_size(width, height);
    shm_unlink(name); /* clear any stale segment from a crashed helper */
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0)
        return NULL;
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        shm_unlink(name);
        return NULL;
    }
    nes_shm_t *shm = map_fd(fd, size);
    if (!shm) {
        shm_unlink(name);
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

nes_shm_t *nes_shm_open(const char *name) {
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(nes_shm_t)) {
        close(fd);
        return NULL;
    }
    size_t mapped = (size_t)st.st_size;
    nes_shm_t *shm = map_fd(fd, mapped);
    if (!shm)
        return NULL;
    /* >= not ==: shm ftruncate rounds the object up to a page multiple. */
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

void nes_shm_close(nes_shm_t *shm, const char *name, int is_creator) {
    if (shm)
        munmap(shm, nes_shm_total_size(shm->width, shm->height));
    if (is_creator && name)
        shm_unlink(name);
}
