#ifndef BAND9_FFI_H
#define BAND9_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

// Version points to static memory. Do not free it.
const char *band9_core_version(void);
// The returned JSON string is owned by Rust and must be released below.
char *band9_diagnose_json(const char *input_json);
void band9_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
