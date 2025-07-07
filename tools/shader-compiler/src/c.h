#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

    int __compileShader(const char *name, const char *path, const char *input,
                        char **outSpirvCode, size_t *outSpirvCodeLen,
                        char **outReflection, size_t *outReflectionLen);

#ifdef __cplusplus
}
#endif
